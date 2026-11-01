import Foundation
import MLaudCore

/// Резидентный распознаватель (`python -m mlaud_worker.dictate`), общий для диктовки и звонка:
/// события без `ch` — клиенту `.dictation`, с `ch` — клиенту `.call` (§2.5).
///
/// Процесс резидентный, в отличие от пакетного worker'а: модель грузится 1.8 с и занимает
/// ~1.6 ГБ, поэтому поднимать её на каждую фразу нельзя. По той же причине она не висит
/// вечно — когда клиентов нет, процесс закрывается по таймеру.
final class RecognizerProcess {
    enum State: Equatable { case off, starting, ready }
    enum Client: Hashable { case dictation, call }

    struct Handlers {
        var onState: (State) -> Void = { _ in }                          // главный поток; .ready после события ready
        var onDictationEvent: (DictationEvent) -> Void = { _ in }        // строки без ch; ready сюда не приходит
        var onChannelEvent: (String, ChannelEvent) -> Void = { _, _ in } // строки с ch
        var onTerminated: (Bool) -> Void = { _ in }                      // unexpected: true — процесс умер сам; после — state == .off
        var onLaunchFailure: (String) -> Void = { _ in }                 // process.run() не удался; state остаётся .off
    }

    let makeCommand: () -> WorkerCommand
    let idleTimeout: TimeInterval
    private(set) var state: State = .off
    var clients: Set<Client> = []

    /// Обработчики переживают release: после `flush`/`close` хвост фразы приходит уже
    /// отпущенному клиенту, и терять его нельзя.
    private var handlers: [Client: Handlers] = [:]
    private var process: Process?
    private var stdinPipe: Pipe?
    private var idleTimer: Timer?
    /// Номер запуска: события и завершение старого процесса после shutdown/смерти игнорируются.
    private var generation = 0

    private let ioQueue = DispatchQueue(label: "mlaud.dictation.io")

    init(makeCommand: @escaping () -> WorkerCommand, idleTimeout: TimeInterval = 300) {
        self.makeCommand = makeCommand
        self.idleTimeout = idleTimeout
    }

    deinit { shutdown() }

    // MARK: - Клиенты

    /// Зарегистрировать клиента: idle-таймер снят; off → запуск (state .starting); уже .ready → handlers.onState(.ready) сразу (синхронно).
    func acquire(_ client: Client, handlers: Handlers) {
        idleTimer?.invalidate()
        idleTimer = nil
        clients.insert(client)
        self.handlers[client] = handlers
        switch state {
        case .ready:
            handlers.onState(.ready)
        case .starting:
            break
        case .off:
            do {
                try launch()
            } catch {
                handlers.onLaunchFailure(error.localizedDescription)
            }
        }
    }

    /// Снять клиента; клиентов нет → idle-таймер idleTimeout → shutdown().
    func release(_ client: Client) {
        clients.remove(client)
        guard clients.isEmpty, process != nil else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.shutdown()
        }
    }

    // MARK: - Команды

    func send(_ command: DictationCommand) {
        write(command.data())
    }

    func send(_ command: ChannelCommand) {
        write(command.data())
    }

    private func write(_ payload: Data) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        ioQueue.async {
            // Процесс мог умереть между проверкой и записью — SIGPIPE прилетает
            // как исключение Objective-C, поэтому пишем через try?.
            try? handle.write(contentsOf: payload)
        }
    }

    // MARK: - Процесс

    private func launch() throws {
        let command = makeCommand()
        let process = command.makeProcess()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        generation += 1
        let gen = generation
        // Буфер строк живёт вместе с процессом и пишется только из этого обработчика.
        var buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: без снятия обработчика источник крутится в пустых чтениях до конца жизни приложения.
                handle.readabilityHandler = nil
                return
            }
            self?.consume(buffer.append(data), generation: gen)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination(generation: gen) }
        }

        try process.run()
        self.process = process
        self.stdinPipe = stdin
        state = .starting
    }

    private func consume(_ lines: [String], generation gen: Int) {
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            for line in lines {
                guard let event = RecognizerEvent.parse(line: line) else { continue }
                self.route(event)
            }
        }
    }

    private func route(_ event: RecognizerEvent) {
        switch event {
        case .dictation(.ready):
            state = .ready
            for h in Array(handlers.values) { h.onState(.ready) }
        case .dictation(let dictationEvent):
            handlers[.dictation]?.onDictationEvent(dictationEvent)
        case .channel(let ch, let channelEvent):
            handlers[.call]?.onChannelEvent(ch, channelEvent)
        }
    }

    private func handleTermination(generation gen: Int) {
        guard gen == generation else { return }
        generation += 1
        process = nil
        stdinPipe = nil
        idleTimer?.invalidate()
        idleTimer = nil
        guard state != .off else { return }
        state = .off
        for h in Array(handlers.values) { h.onTerminated(true) }
    }

    /// quit, terminate через 1 с; state .off; onTerminated(false) всем.
    func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let process else {
            state = .off
            return
        }
        generation += 1
        if process.isRunning {
            send(.quit)
            ioQueue.asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { process.terminate() }
            }
        }
        self.process = nil
        stdinPipe = nil
        let wasOff = state == .off
        state = .off
        guard !wasOff else { return }
        for h in Array(handlers.values) { h.onTerminated(false) }
    }
}
