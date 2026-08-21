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
    private var watchdog: Timer?
    private var stalls = 0

    /// Сколько процесс с моделью живёт без дела, прежде чем освободить память.
    private let idleTimeout: TimeInterval = 300
    /// Столько тишины в приходе буферов считаем поломкой захвата. Не путать с тишиной
    /// в звуке: молчащий микрофон всё равно шлёт буферы, а сломанный тап не шлёт ничего.
    private let stallTimeout: TimeInterval = 4
    /// Ниже этой доли реального времени звук считаем негодным.
    private let minThroughput: Double = 0.5

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
        watchdog?.invalidate()
        watchdog = nil
        stalls = 0
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
        case .stat(let reason, let windowSec, let decodes):
            DictationLog.write("фраза закрыта: \(reason), окно \(windowSec) с, разборов \(decodes)")
        case .error(let message):
            onError?(message)
        }
    }

    private func handleTermination() {
        process = nil
        stdinPipe = nil
        lineBuffer = LineBuffer()
        watchdog?.invalidate()
        watchdog = nil
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
        capture.onDiagnostic = { DictationLog.write($0) }
        capture.onReconfigured = { DictationLog.write($0) }
        capture.onFailure = { [weak self] message in
            DictationLog.write("захват не восстановился: \(message)")
            self?.failCapture(message)
        }
        self.capture = capture
        stalls = 0
        // Запуск асинхронный: обращение к аудиоустройству уходит в coreaudiod и может
        // висеть секундами. В главном потоке этого делать нельзя — встанет всё
        // приложение вместе с горячей клавишей и меню.
        capture.start { [weak self] error in
            guard let self else { return }
            if let error {
                self.capture = nil
                self.state = .off
                self.onError?(error.localizedDescription)
                return
            }
            self.startWatchdog()
        }
    }

    /// Сторож приходящего звука.
    ///
    /// Уведомление о смене конфигурации приходит не всегда: движок может замолчать так,
    /// что объект цел и жалоб нет — приложение показывает «слушаю», распознаватель ждёт
    /// данных на stdin, и оба считают, что всё в порядке. Единственный надёжный признак —
    /// буферы перестали приходить.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkAudioFlow()
        }
    }

    private func checkAudioFlow() {
        guard state == .listening, let capture, let last = capture.lastBufferAt else { return }

        let silentFor = Date().timeIntervalSince(last)
        let throughput = capture.throughput
        // Мало проверять, что буферы приходят. После смены устройства тап оставался
        // настроен под прежнюю частоту и отдавал шестую часть реального времени —
        // «звук идёт», а распознавать нечего. Поэтому сверяем и объём.
        let reason: String
        if silentFor > stallTimeout {
            reason = "буферы не приходят \(Int(silentFor)) с"
        } else if let throughput, throughput < minThroughput {
            reason = "звука приходит \(Int(throughput * 100))% от реального времени"
        } else if throughput == nil {
            // Судить ещё рано (захват только поднялся). Счётчик попыток НЕ сбрасываем:
            // иначе после каждой пересборки он обнулялся, эскалация не наступала
            // никогда, и в журнале бесконечно повторялась «попытка 1».
            return
        } else {
            stalls = 0
            return
        }

        stalls += 1
        DictationLog.write("захват нездоров (\(reason)) — попытка \(stalls) пересобрать")
        guard stalls <= 2 else {
            failCapture("микрофон не восстановился: \(reason)")
            return
        }
        capture.restart { [weak self] ok in
            guard let self, !ok else { return }
            self.failCapture("микрофон не восстановился: \(reason)")
        }
    }

    /// Захват мёртв: честно выключаемся, а не изображаем, что слушаем.
    private func failCapture(_ message: String) {
        watchdog?.invalidate()
        watchdog = nil
        capture?.stop()
        capture = nil
        send(.reset)
        preview = ""
        state = .off
        stalls = 0
        scheduleIdleShutdown()
        onError?(message)
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
        watchdog?.invalidate()
        watchdog = nil
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
