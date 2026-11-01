import AppKit
import MLaudCore

/// Диктовка по горячей клавише: микрофон → резидентный распознаватель → печать
/// в активное поле ввода чужого приложения.
///
/// Процесс распознавателя общий со звонком и живёт в `RecognizerProcess`; здесь —
/// только сеанс диктовки: разрешения, микрофон, сторож звука и печать.
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

    private let process: RecognizerProcess
    private let inserter = TextInserter()
    private var joiner = TextJoiner()
    private var capture: AudioCapture?
    private var watchdog: Timer?
    private var stalls = 0

    /// Столько тишины в приходе буферов считаем поломкой захвата. Не путать с тишиной
    /// в звуке: молчащий микрофон всё равно шлёт буферы, а сломанный тап не шлёт ничего.
    private let stallTimeout: TimeInterval = 4
    /// Ниже этой доли реального времени звук считаем негодным.
    private let minThroughput: Double = 0.5

    init(process: RecognizerProcess) {
        self.process = process
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
        joiner.reset()
        preview = ""
        // acquire при готовом процессе синхронно зовёт onState(.ready); гейт `state == .starting`
        // его пропускает, и переход делается здесь по process.state — без двойного старта захвата.
        process.acquire(.dictation, handlers: makeHandlers())
        switch process.state {
        case .ready:
            state = .listening
            startCapture()
        case .starting:
            state = .starting
        case .off:
            break   // запуск не удался, onLaunchFailure уже отработал
        }
    }

    /// Закончить фразу: остановить микрофон, дослать хвост, оставить процесс тёплым.
    private func finish() {
        watchdog?.invalidate()
        watchdog = nil
        stalls = 0
        capture?.stop()
        capture = nil
        process.send(.flush)
        preview = ""
        state = .off
        process.release(.dictation)
    }

    // MARK: - Процесс распознавателя

    private func makeHandlers() -> RecognizerProcess.Handlers {
        var handlers = RecognizerProcess.Handlers()
        handlers.onState = { [weak self] processState in
            guard let self, processState == .ready, self.state == .starting else { return }
            self.state = .listening
            self.startCapture()
        }
        handlers.onDictationEvent = { [weak self] event in
            self?.handle(event)
        }
        handlers.onTerminated = { [weak self] unexpected in
            self?.handleTermination(unexpected: unexpected)
        }
        handlers.onLaunchFailure = { [weak self] message in
            guard let self else { return }
            self.state = .off
            self.onError?("не удалось запустить распознаватель: \(message)")
        }
        return handlers
    }

    private func handle(_ event: DictationEvent) {
        switch event {
        case .ready:
            break   // приходит через onState
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

    private func handleTermination(unexpected: Bool) {
        watchdog?.invalidate()
        watchdog = nil
        guard state != .off else { return }
        capture?.stop()
        capture = nil
        preview = ""
        state = .off
        process.release(.dictation)
        if unexpected {
            onError?("распознаватель завершился неожиданно")
        }
    }

    // MARK: - Микрофон

    private func startCapture() {
        let capture = AudioCapture { [weak self] pcm in
            self?.process.send(.audio(pcm))
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
                self.process.release(.dictation)
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
        process.send(.reset)
        preview = ""
        state = .off
        stalls = 0
        process.release(.dictation)
        onError?(message)
    }

    // MARK: - Освобождение

    /// Остановить захват и отпустить процесс; сам процесс не убивать — им может пользоваться звонок.
    func shutdown() {
        watchdog?.invalidate()
        watchdog = nil
        capture?.stop()
        capture = nil
        // Недосказанная фраза осталась бы в окне тёплого процесса и попала бы в следующую диктовку.
        if state == .listening { process.send(.reset) }
        preview = ""
        state = .off
        stalls = 0
        process.release(.dictation)
    }

    deinit { shutdown() }
}
