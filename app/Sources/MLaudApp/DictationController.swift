import AppKit
import MLaudCore

/// Диктовка по горячей клавише: микрофон → резидентный распознаватель → печать
/// в активное поле ввода чужого приложения.
///
/// Процесс распознавателя резидентный, в отличие от пакетного worker'а: модель грузится
/// 1.8 с и занимает ~1.6 ГБ, поэтому поднимать её на каждую фразу нельзя. По той же
/// причине она не висит вечно — простаивающий процесс закрывается по таймеру.
final class DictationController {
    enum State: Equatable {
        case off
        case starting        // процесс поднят, модель грузится
        case listening

        var debugName: String {
            switch self {
            case .off: return "выключено"
            case .starting: return "загрузка модели"
            case .listening: return "слушаю"
            }
        }
    }

    private(set) var state: State = .off { didSet { if oldValue != state { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    /// Отдельно от onError: без «Универсального доступа» печатать некуда, и это
    /// единственная ошибка, которую пользователь может исправить только руками
    /// в системных настройках — уведомления тут мало, нужен диалог с кнопкой.
    var onNeedsAccessibility: (() -> Void)?
    /// Незакоммиченный хвост: распознан, но ещё может перепишаться, поэтому в чужое
    /// поле он не печатается. Задел под всплывающую подсказку у курсора; в меню его
    /// не показываем — оно перестраивалось бы четыре раза в секунду.
    private(set) var preview: String = ""

    private let makeCommand: () -> WorkerCommand
    private let inserter = TextInserter()
    private var joiner = TextJoiner()
    private var capture: AudioCapture?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var lineBuffer = LineBuffer()
    private var idleTimer: Timer?

    /// Сколько процесс с моделью живёт без дела, прежде чем освободить память.
    private let idleTimeout: TimeInterval = 300

    private let ioQueue = DispatchQueue(label: "mlaud.dictation.io")

    init(makeCommand: @escaping () -> WorkerCommand) {
        self.makeCommand = makeCommand
    }

    // MARK: - Управление

    /// Нажали горячую клавишу.
    func toggle() {
        switch state {
        case .off:      begin()
        case .starting: break          // модель ещё грузится, второе нажатие игнорируем
        case .listening: finish()
        }
    }

    private func begin() {
        DictationLog.write("старт: проверяю разрешения")
        AudioCapture.requestPermission { [weak self] granted in
            guard let self else { return }
            DictationLog.write("микрофон: \(granted ? "разрешён" : "ЗАПРЕЩЁН")")
            guard granted else {
                self.onError?("нет доступа к микрофону — включите его в «Конфиденциальность и безопасность»")
                return
            }
            DictationLog.write("универсальный доступ: \(TextInserter.isTrusted ? "есть" : "НЕТ")")
            guard TextInserter.isTrusted else {
                TextInserter.requestTrust()
                self.onNeedsAccessibility?()
                return
            }
            self.startSession()
        }
    }

    private func startSession() {
        idleTimer?.invalidate()
        joiner.reset()
        preview = ""
        if process?.isRunning == true {
            state = .listening
            startCapture()
            return
        }
        state = .starting
        do {
            try launchRecognizer()
        } catch {
            state = .off
            onError?("не удалось запустить распознаватель: \(error.localizedDescription)")
        }
    }

    /// Закончить фразу: остановить микрофон, дослать хвост, оставить процесс тёплым.
    private func finish() {
        capture?.stop()
        capture = nil
        send(.flush)
        preview = ""
        state = .off
        scheduleIdleShutdown()
    }

    // MARK: - Процесс распознавателя

    private func launchRecognizer() throws {
        let command = makeCommand()
        let process = command.makeProcess()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination() }
        }

        try process.run()
        self.process = process
        self.stdinPipe = stdin
    }

    private func consume(_ data: Data) {
        let lines = lineBuffer.append(data)
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for line in lines {
                guard let event = DictationEvent.parse(line: line) else { continue }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: DictationEvent) {
        switch event {
        case .ready:
            guard state == .starting else { return }
            state = .listening
            startCapture()
        case .commit(let text):
            let piece = joiner.next(text)
            if !piece.isEmpty { inserter.type(piece) }
        case .preview(let text):
            preview = text
        case .error(let message):
            onError?(message)
        }
    }

    private func handleTermination() {
        process = nil
        stdinPipe = nil
        lineBuffer = LineBuffer()
        if state != .off {
            capture?.stop()
            capture = nil
            state = .off
            onError?("распознаватель завершился неожиданно")
        }
    }

    private func send(_ command: DictationCommand) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        let payload = command.data()
        ioQueue.async {
            // Процесс мог умереть между проверкой и записью — SIGPIPE прилетает
            // как исключение Objective-C, поэтому пишем через try?.
            try? handle.write(contentsOf: payload)
        }
    }

    // MARK: - Микрофон

    private func startCapture() {
        let capture = AudioCapture { [weak self] pcm in
            self?.send(.audio(pcm))
        }
        do {
            try capture.start()
            self.capture = capture
        } catch {
            state = .off
            onError?(error.localizedDescription)
        }
    }

    // MARK: - Освобождение памяти

    private func scheduleIdleShutdown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.shutdown()
        }
    }

    func shutdown() {
        idleTimer?.invalidate()
        idleTimer = nil
        capture?.stop()
        capture = nil
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        send(.quit)
        ioQueue.asyncAfter(deadline: .now() + 1.0) {
            if process.isRunning { process.terminate() }
        }
    }

    deinit { shutdown() }
}
