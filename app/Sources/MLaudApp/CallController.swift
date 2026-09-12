import AppKit
import MLaudCore

/// Клей звонка на главном потоке: микрофон + звук приложения → запись и распознаватель,
/// состояние — в `CallSession`. Всё тяжёлое живёт в зависимостях (§4.4).
final class CallController {
    struct Dependencies {
        let recognizer: RecognizerProcess
        let inbox: () -> URL?
        let promptRoot: URL
        let modelType: () -> String
        let makeMic: (@escaping (Data) -> Void) -> AudioCapture
        let makeApp: (@escaping (Data) -> Void) -> AppAudioCapture
        let listApps: (@escaping (Result<[CallAppCandidate], AppAudioCapture.Failure>) -> Void) -> Void
        let now: () -> Date
        // Суфлёр этапа 4: nil в --screenshot (нет процессов и Keychain).
        let makePrompter: ((CallSession) -> PrompterController)?
        let connections: LLMConnectionsStore
        let secrets: SecretStore
        let settings: SettingsStore
        let paths: PrompterPaths
    }

    private let deps: Dependencies
    let session: CallSession
    var onChange: ((CallSnapshot) -> Void)?                 // AppDelegate: model.call = $0; publish()
    var onNotify: ((String, String) -> Void)?               // title, body → журнал уведомлений
    private(set) var candidates: [CallAppCandidate] = []
    var selectedApp: CallAppCandidate? {
        didSet { if oldValue != selectedApp { publishDevices() } }
    }

    private static let sampleRate = 16000
    private static let transcriptFileName = "transcript.live.jsonl"
    private static let maxRecognizerRestarts = 3
    private static let restartWindow: TimeInterval = 60
    /// Пороги сторожа микрофона — как у диктовки (DictationController).
    private static let stallTimeout: TimeInterval = 4
    private static let minThroughput: Double = 0.5

    // Чек-лист хранится отдельно: CallSession принимает оба пункта одним входом.
    private var microphoneCheck: CheckItem = .unknown
    private var appAudioCheck: CheckItem = .unknown
    private var outputWatch: OutputDeviceWatch?

    // Состояние одного звонка; сбрасывается в dismiss().
    private var callID: String?
    private var sidecar: ChannelsSidecar?
    private var record: CallRecord?
    private var recorder: CallRecorder?
    private var transcript: LiveTranscript?
    private var tracks: CallTracks?
    private var mic: AudioCapture?
    private var app: AppAudioCapture?
    private var tickTimer: Timer?
    private var watchdog: Timer?
    private var stalls = 0
    private var opened: Set<CallChannel> = []
    private var recognizerHeld = false
    private var restartTimes: [Date] = []
    private var silentSince: [CallChannel: Date] = [:]
    private var recordedFrames = 0

    // Суфлёр этапа 4.
    private(set) var prompter: PrompterController?
    private var brief: (slug: String, brief: Brief)?
    private var agendaTimer: AgendaTimer?
    private var lastPrompterLineID: Int?
    private var outcomeTimeout: Timer?
    /// Статистика ходов для call.json (§3.5); медиана first_card_ms — по факту.
    private var firstCardSamples: [Int] = []
    private var promptTokensTotal = 0
    private var cachedTokensTotal = 0
    private var completionTokensTotal = 0

    init(deps: Dependencies) {
        self.deps = deps
        self.session = CallSession(now: deps.now)
        session.onChange = { [weak self] snapshot in self?.onChange?(snapshot) }
        prompter = deps.makePrompter?(session)
        prompter?.onNotify = { [weak self] title, body in self?.onNotify?(title, body) }
        prompter?.onEvent = { [weak self] event in self?.handlePrompterEvent(event) }
    }

    deinit {
        tickTimer?.invalidate()
        watchdog?.invalidate()
        outputWatch?.stop()
    }

    private var phase: CallPhase { session.snapshot.phase }
    /// Офлайн (этап 5): один микрофон, пометка «Я / не я» по голосу, моно без сайдкара.
    private var offline: Bool { session.snapshot.mode == "offline" }

    // MARK: - Суфлёр (этап 4)

    /// Бриф экрана звонка: заголовок, имя собеседника в сайдкар и call.json (закрывает S3B D3).
    func prepare(brief: (slug: String, brief: Brief)?) {
        self.brief = brief
        session.apply(.captureMode(brief?.brief.mode ?? "vks"))
        guard phase == .idle || phase == .ready else { return }
        if phase == .idle {
            session.apply(.prepare(callID: ChannelsSidecar.callID(startedAt: deps.now()),
                                   title: brief?.brief.title ?? "Звонок"))
        } else if let brief {
            session.apply(.prepare(callID: session.snapshot.callID ?? "", title: brief.brief.title))
        }
    }

    private func handlePrompterEvent(_ event: PrompterEvent) {
        switch event {
        case .cards(_, _, _, _, let usage, let firstCardMs, _, _, _):
            promptTokensTotal += usage.promptTokens
            cachedTokensTotal += usage.cachedTokens
            completionTokensTotal += usage.completionTokens
            if let firstCardMs { firstCardSamples.append(firstCardMs) }
        case .outcome:
            finalizeRecording()          // итоги готовы (или не вышли) — конвертировать запись
        default:
            break
        }
    }

    /// Ход суфлёра по закрытой фразе собеседника; свои фразы копятся (D18).
    private func forwardPhrases(_ lines: [TranscriptLine]) {
        guard let prompter else { return }
        for line in lines where line.id > (lastPrompterLineID ?? 0) {
            lastPrompterLineID = line.id
            if line.ch == .them {
                prompter.phrase(line, allLines: lines, elapsed: session.snapshot.elapsed,
                                agendaManual: session.snapshot.prompter.agenda,
                                notes: session.snapshot.prompter.notes)
            }
        }
    }

    /// Карточки времени и таймерные ходы — локально, без модели (FR-12.7, FP:544).
    private func prompterTick() {
        guard let agendaTimer else { return }
        let prompterSnapshot = session.snapshot.prompter
        agendaTimer.update(agenda: prompterSnapshot.agenda)
        for card in agendaTimer.dueCards(elapsed: session.snapshot.elapsed) {
            session.apply(.timeCard(card))
            if let callID {
                CallStore.appendCard(root: deps.promptRoot, callID: callID, line: Self.cardLine(card))
            }
        }
        if agendaTimer.isTimerTurn(elapsed: session.snapshot.elapsed) {
            prompter?.timerTurn(elapsed: session.snapshot.elapsed,
                                agendaManual: prompterSnapshot.agenda,
                                notes: prompterSnapshot.notes)
        }
    }

    private static func cardLine(_ card: PromptCard) -> String {
        let fields = [#""id":"\#(card.id)""#, #""type":"\#(card.type.rawValue)""#,
                      #""priority":\#(card.priority)"#, #""text":\#(JSONText.quoted(card.text))"#,
                      #""source":"\#(card.source)""#]
        return #"{"turn":null,"card":{\#(fields.joined(separator: ","))}}"#
    }

    /// ⌘↩ / пауза / раскрытие / заметки — из AppCommands.
    func requestHint() { prompter?.requestHint() }

    func setPrompterPaused(_ on: Bool) { prompter?.setPaused(on) }

    func requestDetail(_ cardID: String) { prompter?.detail(cardID: cardID) }

    /// Ретро-исправление метки (этап 5): клик по строке ленты в офлайне перекладывает реплику
    /// «Я» ↔ «не я» — голос мог не узнать или узнать неверно. Строка, ставшая «не я», уходит
    /// суфлёру ходом, как если бы голос узнался сразу (forwardPhrases её уже пропустил).
    func relabelLine(id: Int) {
        guard offline, phase == .running, let transcript else { return }
        guard let line = transcript.relabel(id: id) else { return }
        if line.ch == .them {
            prompter?.phrase(line, allLines: transcript.lines, elapsed: session.snapshot.elapsed,
                             agendaManual: session.snapshot.prompter.agenda,
                             notes: session.snapshot.prompter.notes)
        }
    }

    /// ⌘⇧S: последняя фраза — собеседник; уже помеченные «не я» не трогает.
    func markLastLineThem() {
        guard offline, phase == .running, let transcript else { return }
        if let last = transcript.lines.last, last.ch == .me {
            relabelLine(id: last.id)
        }
    }

    // MARK: - Подготовка

    /// idle → ready: чек-лист (микрофон, звук приложения), устройства, наушники.
    func prepare() {
        guard phase == .idle || phase == .ready else { return }
        if phase == .idle {
            // Настоящий callID рождается в start(); до него — время подготовки.
            session.apply(.prepare(callID: ChannelsSidecar.callID(startedAt: deps.now()), title: "Звонок"))
        }
        microphoneCheck = .checking
        appAudioCheck = .checking
        publishChecklist()
        publishDevices()
        publishHeadphones()
        if outputWatch == nil {
            let watch = OutputDeviceWatch { [weak self] in
                self?.publishHeadphones()
                self?.publishDevices()
            }
            watch.start()
            outputWatch = watch
        }
        AudioCapture.requestPermission { [weak self] granted in
            guard let self else { return }
            self.microphoneCheck = granted
                ? .ok
                : .denied("нет доступа к микрофону — включите его в «Конфиденциальность и безопасность»")
            self.publishChecklist()
        }
        refreshApps()
    }

    func refreshApps() {
        deps.listApps { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let apps):
                self.candidates = apps
                if let selected = self.selectedApp {
                    self.selectedApp = apps.first { $0.pid == selected.pid }
                        ?? apps.first { $0.bundleID == selected.bundleID }
                }
                self.appAudioCheck = apps.isEmpty
                    ? .unavailable("нет приложений с окнами — откройте окно приложения звонка и обновите")
                    : .ok
            case .failure(let failure):
                self.candidates = []
                self.selectedApp = nil
                self.appAudioCheck = Self.checkItem(for: failure)
            }
            self.publishChecklist()
            self.publishDevices()
            // candidates не в снимке: AppDelegate перечитывает их в onChange, а снимок мог не измениться.
            self.onChange?(self.session.snapshot)
        }
    }

    private static func checkItem(for failure: AppAudioCapture.Failure) -> CheckItem {
        switch failure {
        case .needsRestart: return .needsRestart
        case .noContent: return .unavailable("нет приложений с окнами — откройте окно приложения звонка и обновите")
        case .appGone: return .unavailable("приложение закрыто")
        case .stream(let message): return .unavailable(message)
        }
    }

    private static func noAudioReason(for failure: AppAudioCapture.Failure) -> String {
        switch failure {
        case .needsRestart: return "согласие на «Запись экрана» дано — перезапустите MLaud"
        case .noContent: return "нет окна приложения"
        case .appGone: return "приложение закрыто"
        case .stream(let message): return message
        }
    }

    private func publishChecklist() {
        guard phase != .idle else { return }   // поздний ответ после dismiss не должен трогать пустой снимок
        session.apply(.checklist(microphone: microphoneCheck, appAudio: appAudioCheck))
    }

    private func publishDevices() {
        guard phase != .idle else { return }
        let input = AudioCapture.defaultInputDevice().map(AudioCapture.deviceName)
        let output = OutputDevice.defaultDevice().map(OutputDevice.name)
        session.apply(.devices(input: input, output: output, app: selectedApp?.name))
    }

    private func publishHeadphones() {
        guard phase != .idle else { return }
        session.apply(.headphones(OutputDevice.likelySpeakers()))
    }

    // MARK: - Старт

    /// ready → running (только если snapshot.canStart).
    func start() {
        guard session.snapshot.canStart else { return }
        guard let inbox = deps.inbox() else {
            session.apply(.failed("папка inbox не выбрана"))
            return
        }
        let startedAt = deps.now()
        let callID = ChannelsSidecar.callID(startedAt: startedAt)
        let briefInfo = brief
        let isOffline = offline
        let sidecar: ChannelsSidecar? = isOffline
            ? nil
            : ChannelsSidecar(callID: callID,
                              themLabel: briefInfo.map { BriefParser.themLabel($0.brief) } ?? "Собеседник",
                              brief: briefInfo?.brief.title)

        var record = CallRecord(callID: callID, startedAt: startedAt, model: deps.modelType(),
                                channels: isOffline ? [CallChannel.me.key: "Я"] : (sidecar?.channels ?? [:]))
        record.mode = isOffline ? "offline" : "vks"
        record.brief = briefInfo?.brief.title
        record.briefDir = briefInfo?.slug
        record.inputDevice = session.snapshot.inputDeviceName
        record.outputDevice = session.snapshot.outputDeviceName
        record.app = selectedApp.map { CallRecord.App(name: $0.name, bundleID: $0.bundleID, pid: $0.pid) }
        do {
            try CallStore.write(record, root: deps.promptRoot)
        } catch {
            session.apply(.failed("папка звонка: \(error.localizedDescription)"))
            return
        }

        let recorder = CallRecorder(inbox: inbox, callID: callID, sidecar: sidecar,
                                    channels: isOffline ? 1 : 2)
        do {
            try recorder.start()
        } catch {
            try? FileManager.default.removeItem(at: CallStore.folder(root: deps.promptRoot, callID: callID))
            session.apply(.failed(Self.text(for: error)))
            return
        }

        let folder = CallStore.folder(root: deps.promptRoot, callID: callID)
        let transcript = LiveTranscript(labels: isOffline
                ? [.me: "Я", .them: "не я"]
                : [.me: sidecar?.label(.me) ?? "Я", .them: sidecar?.label(.them) ?? "Собеседник"],
                                        fileURL: folder.appendingPathComponent(Self.transcriptFileName))
        transcript.onChange = { [weak self, weak transcript] in
            guard let self, let transcript else { return }
            self.session.apply(.transcript(lines: transcript.lines, tails: transcript.tails))
            self.forwardPhrases(transcript.lines)
        }

        self.callID = callID
        self.sidecar = sidecar
        self.record = record
        self.recorder = recorder
        self.transcript = transcript
        self.tracks = isOffline ? nil : CallTracks(sampleRate: Self.sampleRate)
        agendaTimer = AgendaTimer(expectedMin: briefInfo?.brief.expectedMin ?? 60,
                                  agenda: briefInfo?.brief.agenda ?? [])
        lastPrompterLineID = nil
        firstCardSamples = []
        promptTokensTotal = 0
        cachedTokensTotal = 0
        completionTokensTotal = 0
        opened = []
        restartTimes = []
        silentSince = [:]
        recordedFrames = 0
        stalls = 0

        session.apply(.prepare(callID: callID, title: briefInfo?.brief.title ?? "Звонок"))
        session.apply(.start)
        guard phase == .running else {
            recorder.abort()
            try? FileManager.default.removeItem(at: folder)
            clearCall()
            session.apply(.failed("звонок не стартовал"))
            return
        }
        prompter?.prepare(brief: briefInfo?.brief, briefSlug: briefInfo?.slug, callDir: folder,
                          mode: briefInfo?.brief.mode ?? "vks",
                          connections: deps.connections, secrets: deps.secrets,
                          limits: PrompterCommand.Limits(
                            rpm: deps.settings.promptRPM,
                            costCeilingUSD: deps.settings.promptCostCeilingUSD,
                            debounceSec: 2.5,
                            warmEverySec: 240))

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)   // и пока открыто меню статус-бара
        tickTimer = timer
        startMicrophone()
        startAppAudio()
        acquireRecognizer()
    }

    private static func text(for error: Error) -> String {
        if let failure = error as? CallRecorder.Failure {
            switch failure {
            case .inboxMissing: return "папка inbox не найдена"
            case .io(let message): return "запись: \(message)"
            case .afconvert(let message): return "конвертация: \(message)"
            }
        }
        return error.localizedDescription
    }

    private func tick() {
        guard phase == .running, let recorder else { return }
        session.apply(.tick)
        prompterTick()
        guard let tracks else {              // офлайн: микрофон непрерывен, добивка не нужна
            session.apply(.recorded(Double(recordedFrames) / Double(Self.sampleRate)))
            return
        }
        // Стерео сливается парами кадров: дорожка без звука (приложение не выбрано, микрофон
        // умер, поток встал) держала бы вторую в памяти и .pcm не рос бы до «Стоп».
        // Тишина по времени звонка — в запись и, пока источник жив, в распознаватель (§2.4).
        for ch in CallChannel.allCases {
            let fill = tracks.catchUp(ch, to: elapsed)
            guard !fill.isEmpty else { continue }
            let interleaved = tracks.push(ch, pcm: fill)
            recorder.append(interleaved: interleaved)
            recordedFrames += interleaved.count / 4
            if opened.contains(ch), hasSource(ch) {
                deps.recognizer.send(.audio(ch: ch.rawValue, pcm: fill))
            }
        }
        session.apply(.recorded(Double(recordedFrames) / Double(Self.sampleRate)))
    }

    /// Захват канала ещё жив: после отказа он снят, и звук уже не придёт.
    private func hasSource(_ ch: CallChannel) -> Bool {
        switch ch {
        case .me: return mic != nil
        case .them: return app != nil
        }
    }

    private var elapsed: TimeInterval {
        guard let startedAt = session.snapshot.startedAt else { return 0 }
        return max(0, deps.now().timeIntervalSince(startedAt))
    }

    // MARK: - Микрофон

    private func startMicrophone() {
        let mic = deps.makeMic { [weak self] pcm in
            DispatchQueue.main.async { self?.onChunk(.me, pcm) }
        }
        mic.onDiagnostic = { DictationLog.write("звонок: \($0)") }
        mic.onReconfigured = { DictationLog.write("звонок: \($0)") }
        mic.onFailure = { [weak self] message in
            DictationLog.write("звонок: захват не восстановился: \(message)")
            self?.failMicrophone(message)
        }
        self.mic = mic
        stalls = 0
        session.apply(.channel(.me, .flowing))
        mic.start { [weak self] error in
            guard let self, self.mic === mic else { return }
            if let error {
                self.failMicrophone(error.localizedDescription)
                return
            }
            self.startWatchdog()
        }
    }

    /// Сторож приходящего звука — та же логика, что у диктовки: буферы перестали приходить
    /// или их объём ниже реального времени → пересобрать, после двух неудач — сдаться.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkMicrophoneFlow()
        }
    }

    private func checkMicrophoneFlow() {
        guard phase == .running, let mic, let last = mic.lastBufferAt else { return }
        let silentFor = deps.now().timeIntervalSince(last)
        let throughput = mic.throughput
        let reason: String
        if silentFor > Self.stallTimeout {
            reason = "буферы не приходят \(Int(silentFor)) с"
        } else if let throughput, throughput < Self.minThroughput {
            reason = "звука приходит \(Int(throughput * 100))% от реального времени"
        } else if throughput == nil {
            return
        } else {
            stalls = 0
            return
        }

        stalls += 1
        DictationLog.write("звонок: микрофон нездоров (\(reason)) — попытка \(stalls) пересобрать")
        guard stalls <= 2 else {
            failMicrophone("микрофон не восстановился: \(reason)")
            return
        }
        mic.restart { [weak self] ok in
            guard let self, !ok else { return }
            self.failMicrophone("микрофон не восстановился: \(reason)")
        }
    }

    /// Микрофон мёртв: канал «Я» помечен, звонок и запись собеседника продолжаются.
    private func failMicrophone(_ message: String) {
        watchdog?.invalidate()
        watchdog = nil
        mic?.stop()
        mic = nil
        stalls = 0
        guard phase == .running else { return }
        session.apply(.channel(.me, .failed(message)))
        session.apply(.failed(message))
    }

    // MARK: - Звук приложения

    private func startAppAudio() {
        if offline {
            session.apply(.channel(.them, .idle))   // канала собеседника нет: один микрофон
            return
        }
        guard let selected = selectedApp else {
            session.apply(.channel(.them, .noAudio("приложение не выбрано")))
            return
        }
        let app = deps.makeApp { [weak self] pcm in
            DispatchQueue.main.async { self?.onChunk(.them, pcm) }
        }
        app.onDiagnostic = { DictationLog.write("звонок: \($0)") }
        app.onFailure = { [weak self] failure in
            guard let self, self.app === app, self.phase == .running else { return }
            DictationLog.write("звонок: звук приложения потерян: \(failure)")
            self.app = nil
            self.session.apply(.channel(.them, .noAudio(Self.noAudioReason(for: failure))))
        }
        self.app = app
        app.start(app: selected) { [weak self] failure in
            guard let self, self.app === app, self.phase == .running else { return }
            if let failure {
                DictationLog.write("звонок: звук приложения не подключился: \(failure)")
                app.stop()
                self.app = nil
                self.session.apply(.channel(.them, .noAudio(Self.noAudioReason(for: failure))))
                return
            }
            self.session.apply(.channel(.them, .flowing))
        }
    }

    // MARK: - Распознаватель

    private func acquireRecognizer() {
        recognizerHeld = true
        var handlers = RecognizerProcess.Handlers()
        handlers.onState = { [weak self] state in
            guard let self, state == .ready, self.phase == .running, self.recognizerHeld else { return }
            self.openChannels()
            self.session.apply(.recognizer(.ready))
        }
        handlers.onChannelEvent = { [weak self] ch, event in
            guard let self, let channel = CallChannel(rawValue: ch), let transcript = self.transcript else { return }
            if case .error(let message) = event {
                DictationLog.write("звонок: канал \(ch): \(message)")
            }
            if self.offline, case .phrase(let phrase) = event {
                // Этап 5: физический канал один; метка строки — по голосу (S4), свои — «Я»,
                // чужие — «не я», короче 2 с — «?». Ход суфлёра триггерят «не я»-фразы (them).
                let routed = OfflineVoicePolicy.route(phrase)
                transcript.apply(routed.ch, event, label: routed.label)
            } else {
                transcript.apply(channel, event)
            }
        }
        handlers.onTerminated = { [weak self] unexpected in
            self?.recognizerTerminated(unexpected: unexpected)
        }
        handlers.onLaunchFailure = { [weak self] message in
            guard let self, self.phase == .running else { return }
            self.session.apply(.recognizer(.failed("не удалось запустить распознаватель: \(message)")))
        }
        deps.recognizer.acquire(.call, handlers: handlers)
        if deps.recognizer.state == .starting, !isRestarting {
            session.apply(.recognizer(.loading))
        }
    }

    private var isRestarting: Bool {
        if case .restarting = session.snapshot.recognizer { return true }
        return false
    }

    /// Только после ready: звук до него пишется, но не шлётся, а `open` несёт смещение
    /// головы записи канала — так t0/t1 ленты совпадают с позицией в .m4a (§3.3, D13).
    private func openChannels() {
        guard let transcript else { return }
        if offline {
            // Один микрофон с живой пометкой голоса; время — от принятого звука (запись моно).
            deps.recognizer.send(.open(ch: CallChannel.me.rawValue, label: "Я", voice: true))
            transcript.open(CallChannel.me, offset: 0)
            opened.insert(CallChannel.me)
            return
        }
        guard let tracks, let sidecar else { return }
        for ch in CallChannel.allCases {
            let offset = Double(tracks.samples(ch)) / Double(Self.sampleRate)
            deps.recognizer.send(.open(ch: ch.rawValue, label: sidecar.label(ch)))
            transcript.open(ch, offset: offset)
            opened.insert(ch)
        }
    }

    private func recognizerTerminated(unexpected: Bool) {
        opened = []
        guard phase == .running, recognizerHeld else { return }
        guard unexpected else {
            session.apply(.recognizer(.off))
            return
        }
        let now = deps.now()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < Self.restartWindow }
        guard restartTimes.count < Self.maxRecognizerRestarts else {
            DictationLog.write("звонок: распознаватель падает подряд — больше не перезапускаю, запись продолжается")
            session.apply(.recognizer(.failed("распознаватель завершился неожиданно")))
            return
        }
        restartTimes.append(now)
        let attempt = restartTimes.count
        DictationLog.write("звонок: распознаватель завершился неожиданно — перезапуск \(attempt)")
        session.apply(.recognizer(.restarting(attempt: attempt)))
        acquireRecognizer()
    }

    // MARK: - Звук

    private func onChunk(_ ch: CallChannel, _ pcm: Data) {
        guard phase == .running, let recorder, !pcm.isEmpty else { return }
        if offline {
            guard ch == .me else { return }
            recorder.append(interleaved: pcm)     // моно: байты как есть
            recordedFrames += pcm.count / 2
            if opened.contains(.me) {
                deps.recognizer.send(.audio(ch: CallChannel.me.rawValue, pcm: pcm))
            }
            healthFor(ch, pcm)
            return
        }
        guard let tracks else { return }
        let aligned = tracks.align(ch, pcm: pcm, at: elapsed)
        let interleaved = tracks.push(ch, pcm: aligned)
        recorder.append(interleaved: interleaved)
        recordedFrames += interleaved.count / 4
        if opened.contains(ch) {
            deps.recognizer.send(.audio(ch: ch.rawValue, pcm: aligned))
        }
        healthFor(ch, aligned)
    }

    private func healthFor(_ ch: CallChannel, _ pcm: Data) {
        let rms = AudioPCM.rms(int16: pcm)
        session.apply(.level(ch, rms))
        let now = deps.now()
        if rms >= 0.006 {
            silentSince[ch] = nil
        } else if silentSince[ch] == nil {
            silentSince[ch] = now
        }
        let silentFor = silentSince[ch].map { now.timeIntervalSince($0) } ?? 0
        session.apply(.channel(ch, AppAudioPolicy.health(rms: rms, silentFor: silentFor)))
    }

    // MARK: - Стоп

    /// running → finishing → done. Конвертация записи — после итогов суфлёра (§3.7):
    /// outcome.md должен существовать раньше .m4a, иначе конвейер не найдёт его для артефакта.
    func stop() {
        guard phase == .running, let recorder else { return }
        stopCaptures()
        closeChannels()
        if let tracks {
            recorder.append(interleaved: tracks.finish())
        }
        session.apply(.stop)
        releaseRecognizer()
        outcomeDone = false

        let snapshot = session.snapshot.prompter
        let enabled: Bool
        switch snapshot.status {
        case .off, .disabled: enabled = false
        default: enabled = prompter != nil
        }
        if enabled {
            prompter?.finish(elapsed: session.snapshot.elapsed,
                             notes: snapshot.notes)
            outcomeTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                self?.finalizeRecording()
            }
        } else {
            session.apply(.outcomeState(.none))
            finalizeRecording()
        }
    }

    private var outcomeDone = true

    /// Итоги пришли (или не нужны) — конвертировать запись и закрыть звонок. Один раз.
    private func finalizeRecording() {
        guard !outcomeDone, phase == .finishing, let recorder else { return }
        outcomeDone = true
        outcomeTimeout?.invalidate()
        outcomeTimeout = nil
        prompter?.shutdown()

        let endedAt = deps.now()
        let elapsed = session.snapshot.startedAt.map { endedAt.timeIntervalSince($0) } ?? session.snapshot.elapsed
        let snapshot = session.snapshot.prompter
        if let callID {
            CallStore.writeNotes(root: deps.promptRoot, callID: callID, notes: snapshot.notes)
        }
        recorder.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                if var record = self.record {
                    record.endedAt = endedAt
                    record.durationSec = (elapsed * 10).rounded() / 10
                    record.recording = output.audio.lastPathComponent
                    if let connection = self.prompter?.connection, snapshot.status != .off {
                        record.prompter = CallRecord.PrompterStats(
                            enabled: true,
                            connection: connection.name,
                            llmModel: connection.model,
                            turns: snapshot.turns,
                            promptTokens: self.promptTokensTotal,
                            cachedTokens: self.cachedTokensTotal,
                            completionTokens: self.completionTokensTotal,
                            costUSD: snapshot.costUSD,
                            firstCardMsMedian: Self.median(self.firstCardSamples))
                    }
                    record.goalResult = snapshot.outcome?.goalResult
                    self.record = record
                    do {
                        try CallStore.write(record, root: self.deps.promptRoot)
                    } catch {
                        DictationLog.write("звонок: call.json не обновился: \(error.localizedDescription)")
                    }
                }
                self.session.apply(.finalized(output.audio))
                self.onNotify?("Суфлёр", "Файл отправлен в inbox")
            case .failure(let failure):
                self.session.apply(.failed(Self.text(for: failure)))
            }
        }
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Отмена итогов пользователем — конвертировать сразу (§3.7).
    func cancelOutcome() {
        prompter?.cancelOutcome()
        finalizeRecording()
    }

    private func stopCaptures() {
        tickTimer?.invalidate()
        tickTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        mic?.stop()
        mic = nil
        app?.stop()
        app = nil
    }

    private func closeChannels() {
        for ch in opened {
            deps.recognizer.send(.flush(ch: ch.rawValue))
            deps.recognizer.send(.close(ch: ch.rawValue))
        }
        opened = []
    }

    private func releaseRecognizer() {
        guard recognizerHeld else { return }
        recognizerHeld = false
        deps.recognizer.release(.call)
    }

    func dismiss() {
        guard phase == .ready || phase == .done else { return }
        outputWatch?.stop()
        outputWatch = nil
        microphoneCheck = .unknown
        appAudioCheck = .unknown
        clearCall()
        session.apply(.dismiss)
    }

    private func clearCall() {
        callID = nil
        sidecar = nil
        record = nil
        recorder = nil
        transcript = nil
        tracks = nil
        opened = []
        restartTimes = []
        silentSince = [:]
        recordedFrames = 0
        agendaTimer = nil
        lastPrompterLineID = nil
        firstCardSamples = []
        promptTokensTotal = 0
        cachedTokensTotal = 0
        completionTokensTotal = 0
        outcomeTimeout?.invalidate()
        outcomeTimeout = nil
        outcomeDone = true
    }

    /// Остановить захваты и отпустить распознаватель; .incoming/<id>.pcm и сайдкар остаются —
    /// на следующем запуске CallRecorder.recover доделает .m4a.
    func suspendForQuit() {
        outputWatch?.stop()
        outputWatch = nil
        outcomeTimeout?.invalidate()
        outcomeTimeout = nil
        guard phase == .running else {
            releaseRecognizer()
            return
        }
        stopCaptures()
        closeChannels()
        if let recorder, let tracks {
            recorder.append(interleaved: tracks.finish())
        }
        releaseRecognizer()
    }
}
