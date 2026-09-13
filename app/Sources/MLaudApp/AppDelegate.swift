import AppKit
import AVFoundation
import MLaudCore
import NitiUI
import UserNotifications

/// Оболочка: строка меню, главное окно, процессы (worker, распознаватель, приём с iPhone),
/// слежение за папкой. Экраны видят её через `AppModel` (состояние) и `AppCommands` (действия).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let folderStore = FolderStore()
    private let settingsStore = SettingsStore()
    private let settings: SettingsModel
    private lazy var model = AppModel(settings: settings, voices: voices)
    private let scanner = InboxScanner()
    private var mainWindow: MainWindowController!
    /// `--screenshot <каталог>`: снять экраны и выйти. Движки в этом режиме не запускаются —
    /// рядом может работать установленное приложение на той же папке.
    private let screenshotDirectory: URL?
    private var previewOnly: Bool { screenshotDirectory != nil }

    private var status: ProcessingStatus = .noFolder { didSet { publish() } }
    private var isProcessing = false
    private var sweepTimer: Timer?
    private var watcher: FolderWatcher?
    private var debounceWork: DispatchWorkItem?
    /// Сайдкары записей для разметки голосов. Счётчик «к разметке» кешируется:
    /// publish() дёргается на каждое уведомление, а сканировать каталог каждый раз незачем.
    private lazy var speakers = SpeakerSidecarStore(
        root: serviceDirectory.appendingPathComponent("speakers"))
    private var pendingVoices = 0
    /// Раздел «Голоса»: после каждого действия worker'а — пересчитать счётчик и список записей.
    private lazy var voices = VoicesModel(store: speakers, runner: makeVoicesRunner()) { [weak self] in
        self?.refreshPendingVoices()
        self?.reloadRecordings()
        self?.publish()
    }
    /// Журнал уведомлений: баннер исчезает через несколько секунд, прочитать
    /// написанное нужно и позже.
    private lazy var notifications = NotificationHistory(
        url: serviceDirectory.appendingPathComponent("notifications.json"))
    private lazy var phoneSync = PhoneSyncController(serviceDirectory: serviceDirectory)
    /// Резидентный распознаватель, общий для диктовки и звонка. Замыкание держит значения,
    /// а не AppDelegate: пути за время жизни приложения не меняются, а настройки живут в своём объекте.
    private lazy var recognizer: RecognizerProcess = {
        let python = self.pythonExecutable
        let workerDir = self.workerDirectory
        let extraPath = self.additionalPythonPath
        let inbox = self.folderStore.inboxFolder ?? self.fm.homeDirectoryForCurrentUser
        let store = self.settingsStore
        return RecognizerProcess {
            var env = store.workerEnvironment()
            env["PYTHONUNBUFFERED"] = "1"  // события должны выходить сразу, а не пачкой
            return WorkerCommand(
                pythonExecutable: python,
                workerDirectory: workerDir,
                inboxFolder: inbox,
                additionalPythonPath: extraPath,
                extraEnvironment: env,
                module: "mlaud_worker.dictate"
            )
        }
    }()
    private var dictation: DictationController?
    /// Звонок суфлёра: создаётся лениво при первом «начать звонок», не в `--screenshot`.
    private var call: CallController?
    private var hotKey: HotKey?
    /// Не удалось занять сочетание: показываем в меню и на экране, иначе диктовка выглядит
    /// просто сломанной.
    private var hotKeyFailed = false

    private let fm = FileManager.default

    init(screenshotDirectory: URL?) {
        self.screenshotDirectory = screenshotDirectory
        settings = SettingsModel(store: settingsStore)
        super.init()
    }

    // MARK: - Пути

    /// Ресурсы внутри .app (если запущены из бандла, а не через `swift run`).
    private var bundledResources: URL? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return Bundle.main.resourceURL
    }

    // Пути: env-переопределение → вложенный бандл → dev-пути репозитория.
    private var pythonExecutable: URL {
        if let p = ProcessInfo.processInfo.environment["MLAUD_PY"] { return URL(fileURLWithPath: p) }
        if let res = bundledResources {
            let bundled = res.appendingPathComponent("python/bin/python3")
            if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        // dev-фолбэк (`swift run` из каталога app/): путь относительно репозитория. Без
        // standardized `Process` не находит файл по пути с `..` («The file “python” doesn’t exist»).
        return URL(fileURLWithPath: "../poc/.venv/bin/python").standardizedFileURL
    }
    private var workerDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["MLAUD_WORKER_DIR"] { return URL(fileURLWithPath: p) }
        if let res = bundledResources {
            let bundled = res.appendingPathComponent("worker")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: "../worker", isDirectory: true).standardizedFileURL
    }
    /// Доп. PYTHONPATH: вложенный site-packages (в бандле), иначе пусто (dev-venv самодостаточен).
    private var additionalPythonPath: [URL] {
        if let res = bundledResources {
            let sp = res.appendingPathComponent("site-packages")
            if fm.fileExists(atPath: sp.path) { return [sp] }
        }
        return []
    }
    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var resultsDirectory: URL { home.appendingPathComponent("ASR/ASROutput/AllOutputs") }
    /// Архив обработанного аудио — тот же путь, что `Config.default().processed` у worker'а.
    private var archiveDirectory: URL { home.appendingPathComponent("ASR/Processed/AllRecords") }
    /// Карантин упавших файлов — тот же путь, что `Config.default().failed` у worker'а.
    private var failedDirectory: URL { home.appendingPathComponent("ASR/Failed") }
    /// Служебная папка приложения: логи, состояние, данные приёма с телефона.
    private var serviceDirectory: URL { home.appendingPathComponent("ASR/service") }
    /// Лог worker'а: stdout+stderr Python-процесса. Без него ошибки невидимы (exit-код без причины).
    private var workerLogURL: URL { serviceDirectory.appendingPathComponent("worker.log") }
    /// Корень `Prompter/` (D1: MLAUD_PROMPTER_DIR — корень, не `calls`); папки звонков — calls.
    private let prompterPaths = PrompterPaths.resolve()
    private var promptRoot: URL { prompterPaths.calls }
    /// Ключи модели: Keychain в установленном приложении, память в --screenshot (D10).
    private lazy var prompterSecrets: SecretStore = previewOnly ? InMemorySecretStore() : KeychainStore()
    /// Подключения модели в UserDefaults; пресеты сеются при первом чтении (FR-12.13).
    private lazy var llmConnections = LLMConnectionsStore(defaults: .standard)
    private var prompterPaused = false
    private var compactPanel: CompactPanelController?

    /// Недоставленные транскрипты (сеть падала при обработке): досылаются воркером при
    /// следующем прогоне — даже если inbox пуст.
    private var pendingDeliveryCount: Int {
        let url = serviceDirectory.appendingPathComponent("pending_delivery.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return 0 }
        return arr.count
    }

    // MARK: - Запуск

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Строго до конца запуска: иначе система не отдаст отклик на баннер,
        // по которому кликнули, пока приложение поднималось.
        UserNotifier.setDelegate(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.onChange = { [weak self] change in self?.apply(change) }
        // Суфлёр этапа 4: посев шаблонов брифов и пресетов подключений; профиль — в model.
        if !previewOnly {
            try? BriefStore.seedTemplates(paths: prompterPaths)
            model.templates = BriefStore.templates(paths: prompterPaths)
            _ = llmConnections.all          // сеет пресеты
            refreshConnections()
            settings.profileText = (try? String(contentsOf: prompterPaths.profile, encoding: .utf8)) ?? ""
            model.prompterView = .list
            refreshSelfVoice()
        }
        model.commands = self
        mainWindow = MainWindowController(model: model)
        NSApp.mainMenu = MainMenu.build(delegate: self, windowController: mainWindow)
        status = folderStore.hasInboxFolder ? .idle : .noFolder

        if let screenshotDirectory {
            // У dev-запуска свои defaults без папки; для снимков её можно подставить. Только в
            // памяти процесса: registration domain на диск не пишется, и следующий dev-запуск
            // с движками не начнёт обрабатывать папку установленного приложения.
            if let path = ProcessInfo.processInfo.environment["MLAUD_INBOX"] {
                UserDefaults.standard.register(defaults: [FolderStore.inboxKey: path])
                status = folderStore.hasInboxFolder ? .idle : .noFolder
            }
            reloadRecordings()
            Screenshots.run(window: mainWindow, model: model, directory: screenshotDirectory) {
                NSApp.terminate(nil)
            }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if settings.notificationsEnabled {
            UserNotifier.requestAuthorization()
        }
        // Пробуждение из сна → разобрать накопленное.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Периодический «подметающий» проход (страховка от пропущенных событий/iCloud-лага).
        sweepTimer = Timer.scheduledTimer(
            timeInterval: 120, target: self, selector: #selector(autoProcess),
            userInfo: nil, repeats: true)
        restartWatcher()
        restartDictation()
        restartPhoneSync()
        refreshPendingVoices()
        reloadRecordings()
        recoverCalls()
        publish()
        autoProcess()  // подхватить файлы, накопившиеся пока приложение не работало
    }

    /// Запись звонка, оборванная крахом: `.incoming/<id>.pcm` при сайдкаре в inbox доделывается
    /// до `.m4a` (NFR-4), конвейер подхватит файл обычным путём.
    private func recoverCalls() {
        guard let inbox = folderStore.inboxFolder else { return }
        CallRecorder.recover(inbox: inbox) { [weak self] outputs in
            guard let self, !outputs.isEmpty else { return }
            for output in outputs {
                self.notify(title: "Суфлёр — запись восстановлена", body: output.audio.lastPathComponent)
            }
            DispatchQueue.main.async { self.autoProcess() }
        }
    }

    /// Клик по иконке в Dock, пока окно закрыто, но приложение ещё `.regular`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        call?.suspendForQuit()   // захваты стоп, файлы .incoming остаются — recover доделает
        dictation?.shutdown()
        recognizer.shutdown()    // резидентная модель держит ~1.6 ГБ — отпускаем явно
    }

    /// Побочный эффект смены настройки — по ключу, а не «перезапустить всё».
    private func apply(_ change: SettingsModel.Change) {
        guard !previewOnly else { return }
        switch change {
        case .watcher: restartWatcher()
        case .dictation: restartDictation()
        case .phoneSync: restartPhoneSync()
        case .voices: refreshPendingVoices()
        case .notifications: if settings.notificationsEnabled { UserNotifier.requestAuthorization() }
        }
        publish()
    }

    // MARK: - Состояние для экранов и строки меню

    /// Единственная точка обновления всего, что видно: иконка, меню, модель экранов.
    private func publish() {
        refreshStatusItem()

        var overview = OverviewState()
        overview.status = status
        overview.inboxPath = folderStore.inboxFolder?.path
        if let folder = folderStore.inboxFolder {
            overview.ready = scanner.readyAudioFiles(in: folder).count
            overview.downloading = scanner.downloadingAudioFiles(in: folder).count
        }
        overview.pendingDelivery = pendingDeliveryCount
        overview.quarantine = quarantineFiles()
        overview.recent = Array(model.recordings.prefix(OverviewState.recentLimit))
        if case .error = status { overview.lastLogLine = lastWorkerError() }
        model.overview = overview

        model.notifications = notifications.records
        model.unreadCount = notifications.unreadCount

        model.phone = phoneSync.state
        model.phoneLastReceived = phoneSync.lastReceived
        model.phoneReceipts = PhoneReceipts.load(serviceDirectory.appendingPathComponent("sync/received.json"))

        model.dictation = dictation?.state ?? .off
        model.hotKeyFailed = hotKeyFailed
        model.microphone = microphoneStatus()
        model.accessibilityTrusted = TextInserter.isTrusted
        model.dictationLog = DictationLog.tail(30)

        model.voicesPending = pendingVoices
    }

    private func microphoneStatus() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func quarantineFiles() -> [URL] {
        guard let items = try? fm.contentsOfDirectory(
            at: failedDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func refreshStatusItem() {
        guard let statusItem else { return }
        if let button = statusItem.button {
            // Во время диктовки и звонка иконка другая — иначе не видно, что микрофон открыт (ux-app.md §5).
            let symbol: String
            if model.call.phase == .running {
                symbol = "waveform.badge.mic"
            } else {
                symbol = dictation?.state == .off || dictation == nil ? "waveform" : "mic.fill"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MLaud")
            button.image?.isTemplate = true
            // Бейдж непрочитанных: иначе о пропущенном баннере узнать неоткуда.
            let unread = notifications.unreadCount
            button.title = unread > 0 ? " \(unread)" : ""
            button.imagePosition = unread > 0 ? .imageLeading : .imageOnly
        }
        statusItem.menu = buildMenu()
    }

    /// Меню строки — ux-app.md §5: статус и быстрые действия; всё остальное — в окне.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusLine = NSMenuItem(title: status.menuTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if settings.phoneSyncEnabled {
            var title = phoneSync.state.menuTitle
            if let last = phoneSync.lastReceived {
                let time = DateFormatter.localizedString(from: last.at, dateStyle: .none, timeStyle: .short)
                title += " · последняя \(time)"
            }
            let syncLine = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            syncLine.isEnabled = false
            menu.addItem(syncLine)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Открыть MLaud", action: #selector(openMainWindow), keyEquivalent: ""))

        let processItem = NSMenuItem(title: "Обработать сейчас", action: #selector(processNow), keyEquivalent: "r")
        processItem.isEnabled = folderStore.hasInboxFolder && !isProcessing
        menu.addItem(processItem)

        switch model.call.phase {
        case .running, .finishing:
            let clock = NitiTimerLabel.clock(model.call.elapsed)
            let title = model.call.phase == .running ? "Суфлёр: звонок \(clock) — Стоп" : "Суфлёр: звонок \(clock) — завершение…"
            let item = NSMenuItem(title: title, action: #selector(stopCall), keyEquivalent: "")
            menu.addItem(item)
        case .idle, .ready, .done:
            menu.addItem(NSMenuItem(title: "Суфлёр: начать звонок…", action: #selector(startCallSetup), keyEquivalent: ""))
        }

        if settings.dictationEnabled {
            let combo = settings.dictationHotKey.display
            let title: String
            switch dictation?.state ?? .off {
            case .off:       title = "Диктовка (\(combo))"
            case .starting:  title = "Диктовка: загружаю модель…"
            case .listening: title = "Диктовка: слушаю — \(combo) чтобы закончить"
            }
            let item = NSMenuItem(title: title, action: #selector(toggleDictation), keyEquivalent: "")
            item.isEnabled = dictation?.state != .starting
            menu.addItem(item)
            if hotKeyFailed {
                let warn = NSMenuItem(
                    title: "  \(combo) занято — выбери другое в настройках",
                    action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
            }
        }

        menu.addItem(.separator())
        let unread = notifications.unreadCount
        let notificationsTitle = unread > 0
            ? "Уведомления (\(unread) \(RussianPlural.form(unread, "новое", "новых", "новых")))…"
            : "Уведомления…"
        menu.addItem(NSMenuItem(title: notificationsTitle, action: #selector(openNotifications), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    // MARK: - Окно

    @objc func openMainWindow() { mainWindow.show() }
    @objc func openSettings() { mainWindow.show(section: .settings) }
    @objc func openNotifications() { mainWindow.show(section: .notifications) }

    // MARK: - Слежение за папкой

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        guard settings.instantWatch, let folder = folderStore.inboxFolder else { return }
        let w = FolderWatcher(url: folder) { [weak self] in
            DispatchQueue.main.async { self?.scheduleAutoProcess() }
        }
        w.start()
        watcher = w
    }

    /// Дебаунс: коалесцируем серию файловых событий в один прогон.
    private func scheduleAutoProcess() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoProcess() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Обработка

    @objc private func autoProcess() {
        guard !previewOnly, folderStore.hasInboxFolder, !isProcessing else { return }
        guard let folder = folderStore.inboxFolder else { return }
        // Запускаем воркер, если есть новые файлы ИЛИ висит недоставленное в очереди.
        guard !scanner.readyAudioFiles(in: folder).isEmpty || pendingDeliveryCount > 0 else { return }
        processNow()
    }

    @objc func processNow() {
        guard !previewOnly, let folder = folderStore.inboxFolder, !isProcessing else { return }
        let pending = scanner.readyAudioFiles(in: folder)
        // Прогон «только досыл» (файлов нет, но очередь непуста) — допустим.
        let flushOnly = pending.isEmpty
        guard !pending.isEmpty || pendingDeliveryCount > 0 else { status = .idle; return }

        isProcessing = true
        status = .processing(current: 0, total: pending.count)

        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folder,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: settingsStore.workerEnvironment()
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: ProcessingStatus
            do {
                let process = command.makeProcess()
                let logHandle = self.openWorkerLog()
                if let logHandle {
                    process.standardOutput = logHandle
                    process.standardError = logHandle
                }
                try process.run()
                process.waitUntilExit()
                try? logHandle?.close()
                if process.terminationStatus == 0 {
                    result = .done(count: pending.count)
                } else {
                    let hint = self.lastWorkerError() ?? "см. лог: \(self.workerLogURL.path)"
                    result = .error("worker exit \(process.terminationStatus) — \(hint)")
                }
            } catch {
                result = .error(error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                self.refreshPendingVoices()
                if self.model.section == .voices { self.voices.reload() }
                self.reloadRecordings()
                if flushOnly {
                    // Тихий досыл очереди: без уведомления «Готово: 0» и без дебаунс-
                    // ретригера — независимо от кода возврата. Ретригер здесь и был
                    // мотором busy-loop'а: worker при непустой очереди отдавал ненулевой
                    // код, приложение считало это ошибкой, показывало уведомление и
                    // перезапускало worker через 1.5 с. Повтор — sweep-таймером раз в 120 с.
                    self.status = .idle
                } else {
                    self.status = result
                    self.notifyResult(result, count: pending.count)
                    // вдруг за время обработки накидали ещё файлов
                    self.scheduleAutoProcess()
                }
            }
        }
    }

    private func notifyResult(_ result: ProcessingStatus, count: Int) {
        switch result {
        case .done:
            var body = "Обработано файлов: \(count)"
            var action: String?
            if settings.identifyEnabled, pendingVoices > 0 {
                let word = RussianPlural.form(pendingVoices, "голос", "голоса", "голосов")
                body += " · к разметке: \(pendingVoices) \(word)"
                action = "voices"
            }
            notify(title: "MLaud — готово", body: body, action: action)
        case .error(let message):
            notify(title: "MLaud — ошибка", body: message)
        default:
            break
        }
    }

    /// Индекс архива — в фоне: сотни файлов и сайдкаров, главному потоку там делать нечего.
    /// Заодно список звонков суфлёра и `meeting_id` из `.meta.json` в их `call.json`.
    func reloadRecordings() {
        let index = RecordingIndex(root: resultsDirectory,
                                   speakersRoot: serviceDirectory.appendingPathComponent("speakers"),
                                   archiveRoot: archiveDirectory)
        let promptRoot = self.promptRoot
        let outputRoot = self.resultsDirectory
        let previewOnly = self.previewOnly
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recordings = index.scan()
            // reconcile пишет call.json: в режиме снимков к ~/ASR не прикасаемся.
            if !previewOnly { CallStore.reconcileMeetingIDs(root: promptRoot, outputRoot: outputRoot) }
            let calls = CallStore.list(root: promptRoot)
            let briefs = BriefStore.list(paths: PrompterPaths(root: promptRoot.deletingLastPathComponent()),
                                         calls: calls)
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.recordings = recordings
                self.model.calls = calls
                if !self.previewOnly { self.model.briefs = briefs }
                self.voices.setArchive(recordings)
                self.publish()
            }
        }
    }

    // MARK: - Уведомления

    /// Единственная точка, через которую приложение сообщает о событии.
    ///
    /// В журнал пишем всегда, баннер показываем по настройке: галка «Системные
    /// уведомления» управляет баннером, а не тем, помнит ли приложение, о чём
    /// сообщало. Диспетчеризация на главный поток здесь, а не у вызывающих:
    /// об ошибках сообщают и фоновые обработчики.
    private func notify(title: String, body: String, action: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let record = self.notifications.append(title: title, body: body, action: action)
            if self.settings.notificationsEnabled {
                UserNotifier.notify(title: title, body: body, identifier: record.id.uuidString)
            }
            self.publish()
        }
    }

    // MARK: - Голоса

    // MARK: - Эталон «Я» (этап 5, FR-8.5)

    /// Каталог базы голосов — тот же, что у worker'а (переопределение как у inbox).
    private var voicesDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["MLAUD_VOICES_DIR"] {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return home.appendingPathComponent("ASR/voices", isDirectory: true)
    }

    /// Есть ли персона «Я» в базе: живая пометка без неё не работает (S4).
    private func refreshSelfVoice() {
        let index = voicesDirectory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: index),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let people = obj["people"] as? [String: Any]
        else {
            model.selfVoiceReady = false
            return
        }
        model.selfVoiceReady = people.keys.contains { $0.lowercased() == "я" }
    }

    private var selfVoiceCapture: AudioCapture?
    private var selfVoiceTimer: Timer?
    private var selfVoicePCM = Data()
    /// 45 с записи: энролмент требует ≥ 30 с именно речи — у непрерывного монолога
    /// с микропаузами на 30 с записи выходит 25–28 с речи и отказ.
    private static let selfVoiceSeconds: Double = 45

    func recordSelfVoice() {
        guard selfVoiceCapture == nil else { return }
        guard dictation?.state != .listening && dictation?.state != .starting else {
            notify(title: "MLaud — голос", body: "сначала выключите диктовку: микрофон один")
            return
        }
        guard model.call.phase != .running else {
            notify(title: "MLaud — голос", body: "во время звонка запись эталона недоступна")
            return
        }
        let capture = AudioCapture { [weak self] pcm in
            DispatchQueue.main.async { self?.selfVoicePCM.append(pcm) }
        }
        capture.onDiagnostic = { DictationLog.write("эталон: \($0)") }
        capture.onFailure = { [weak self] message in
            self?.finishSelfVoice(failed: message)
        }
        selfVoicePCM = Data()
        model.selfVoiceRecording = 0
        capture.start { [weak self] error in
            guard let self, self.selfVoiceCapture === capture else { return }
            if let error {
                self.finishSelfVoice(failed: error.localizedDescription)
                return
            }
            if let mode = AudioCapture.currentMicrophoneMode(), mode != "standard" {
                self.notify(title: "MLaud — голос",
                            body: "Режим микрофона не «Стандартный» (\(mode)) — эталон получится искажённым. Пункт управления → Режим микрофона.")
            }
            let started = Date()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let sec = Date().timeIntervalSince(started)
                if sec >= Self.selfVoiceSeconds {
                    self.finishSelfVoice()
                } else {
                    model.selfVoiceRecording = sec
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.selfVoiceTimer = timer
        }
        selfVoiceCapture = capture
    }

    func cancelSelfVoiceRecording() {
        finishSelfVoice(cancelled: true)
    }

    private func finishSelfVoice(cancelled: Bool = false, failed: String? = nil) {
        selfVoiceTimer?.invalidate()
        selfVoiceTimer = nil
        selfVoiceCapture?.stop()
        selfVoiceCapture = nil
        model.selfVoiceRecording = nil
        if let failed {
            notify(title: "MLaud — голос", body: "запись не удалась: \(failed)")
            return
        }
        guard !cancelled else {
            model.toast = "Запись эталона отменена"
            return
        }
        enrollSelfVoice(selfVoicePCM)
    }

    /// Запись с микрофона → wav → `voices enroll-reference` (диаризация на CPU worker'а).
    private func enrollSelfVoice(_ pcm: Data) {
        let dir = serviceDirectory.appendingPathComponent("self-voice", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ChannelsSidecar.callID(startedAt: Date())
        let wav = dir.appendingPathComponent("\(stamp).wav")
        var data = CallRecorder.wavHeader(dataBytes: pcm.count, channels: 1)
        data.append(pcm)
        do {
            try data.write(to: wav)
        } catch {
            notify(title: "MLaud — голос", body: "файл не записался: \(error.localizedDescription)")
            return
        }
        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folderStore.inboxFolder ?? serviceDirectory,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: settingsStore.workerEnvironment(),
            module: "mlaud_worker.voices",
            moduleArguments: ["enroll-reference", wav.path])
        notify(title: "MLaud — голос", body: "считаю отпечаток…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = command.makeProcess()
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            _ = try? process.run()
            process.waitUntilExit()
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                self?.refreshSelfVoice()
                self?.notify(title: "MLaud — голос",
                             body: ok ? "Голос записан в базу как «Я»" : "Не получилось: " + text.prefix(120))
            }
        }
    }

    private func refreshPendingVoices() {
        pendingVoices = settings.identifyEnabled ? speakers.pendingCount() : 0
    }

    private func makeVoicesRunner() -> VoicesRunner {
        VoicesRunner(
            makeCommand: { [unowned self] args in
                WorkerCommand(
                    pythonExecutable: self.pythonExecutable,
                    workerDirectory: self.workerDirectory,
                    inboxFolder: self.folderStore.inboxFolder ?? self.serviceDirectory,
                    additionalPythonPath: self.additionalPythonPath,
                    extraEnvironment: self.settingsStore.workerEnvironment(),
                    module: "mlaud_worker.voices",
                    moduleArguments: args
                )
            },
            log: { [weak self] line in
                guard let self, let handle = self.openWorkerLog() else { return }
                defer { try? handle.close() }
                if let data = (line + "\n").data(using: .utf8) { handle.write(data) }
            }
        )
    }

    /// Открывает лог worker'а на дозапись, дописывая заголовок с временной меткой.
    private func openWorkerLog() -> FileHandle? {
        let url = workerLogURL
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        let header = "\n===== \(ISO8601DateFormatter().string(from: Date())) запуск worker'а =====\n"
        if let data = header.data(using: .utf8) { handle.write(data) }
        return handle
    }

    /// Возвращает последнюю строку FAIL/ошибки из лога (для краткого показа в меню/уведомлении).
    private func lastWorkerError() -> String? {
        guard let text = try? String(contentsOf: workerLogURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        if let fail = lines.last(where: { $0.hasPrefix("FAIL ") || $0.contains("Error") || $0.contains("Traceback") }) {
            return String(fail.prefix(200))
        }
        return lines.last.map { String($0.prefix(200)) }
    }

    // MARK: - Приём с iPhone

    private func restartPhoneSync() {
        guard settings.phoneSyncEnabled else {
            phoneSync.stop()
            return
        }
        phoneSync.onStateChanged = { [weak self] in self?.publish() }
        phoneSync.onReceived = { [weak self] name in
            guard let self else { return }
            self.notify(title: "MLaud — принято с iPhone", body: name)
            // Не ждём FSEvents: файл уже целиком на месте, обработку можно начинать сразу.
            self.autoProcess()
        }
        phoneSync.start(inbox: folderStore.inboxFolder, serviceDirectory: serviceDirectory)
    }

    // MARK: - Диктовка

    /// Пересобрать диктовку под текущие настройки. Хоткей регистрируется всегда, когда
    /// фича включена; разрешения (микрофон, «Универсальный доступ») спрашиваются лениво,
    /// при первом нажатии — чтобы приложение не дёргало системные запросы на старте.
    private func restartDictation() {
        hotKey?.stop()
        hotKey = nil
        dictation?.shutdown()
        dictation = nil
        guard settings.dictationEnabled else { return }

        let controller = DictationController(process: recognizer)
        controller.onStateChange = { [weak self] state in
            DictationLog.write("состояние: \(state)")
            self?.publish()
        }
        controller.onNeedsAccessibility = { [weak self] in
            DictationLog.write("ОШИБКА: нет «Универсального доступа»")
            self?.presentAccessibilityHelp()
        }
        controller.onError = { [weak self] message in
            DictationLog.write("ОШИБКА: \(message)")
            self?.notify(title: "MLaud — диктовка", body: message)
        }
        dictation = controller

        let combo = settings.dictationHotKey
        let key = HotKey(combo: combo) { [weak self] in
            DictationLog.write("нажато \(combo.display)")
            self?.toggleDictation()
        }
        if key.start() {
            hotKey = key
            hotKeyFailed = false
            DictationLog.write("горячая клавиша \(combo.display) зарегистрирована")
        } else {
            hotKeyFailed = true
            DictationLog.write("НЕ УДАЛОСЬ занять \(combo.display) — комбинация занята")
            notify(title: "MLaud — диктовка",
                   body: "\(combo.display) занято другим приложением; выбери другое сочетание в настройках")
        }
    }

    @objc func toggleDictation() {
        // Третий канал распознавателя не измерен (S1) — во время звонка диктовку нельзя начать;
        // остановить уже идущую можно всегда, иначе она печатает в чужое поле до конца звонка.
        guard dictationToggleAllowed else {
            notify(title: "MLaud — диктовка", body: "во время звонка диктовка недоступна")
            return
        }
        DictationLog.write("переключение диктовки из состояния \(dictation?.state.debugName ?? "нет контроллера")")
        dictation?.toggle()
        publish()
    }

    // MARK: - Суфлёр

    /// Контроллер звонка — лениво: `AudioCapture`/`AppAudioCapture` и запросы к системе только
    /// по воле пользователя, не при запуске и не в `--screenshot`.
    private func callController() -> CallController? {
        guard !previewOnly else { return nil }
        if let call { return call }
        let paths = prompterPaths
        let secrets: SecretStore = prompterSecrets
        let deps = CallController.Dependencies(
            recognizer: recognizer,
            inbox: { [folderStore] in folderStore.inboxFolder },
            promptRoot: promptRoot,
            modelType: { [settingsStore] in settingsStore.modelType },
            makeMic: { AudioCapture(onChunk: $0) },
            makeApp: { AppAudioCapture(onChunk: $0) },
            listApps: AppAudioCapture.candidates,
            now: Date.init,
            makePrompter: { [weak self] session in
                guard let self else {
                    return PrompterController(
                        deps: PrompterController.Dependencies(
                            makeCommand: { _ in WorkerCommand(
                                pythonExecutable: URL(fileURLWithPath: "/usr/bin/true"),
                                workerDirectory: URL(fileURLWithPath: "/"),
                                inboxFolder: URL(fileURLWithPath: "/")) },
                            paths: PrompterPaths(root: URL(fileURLWithPath: "/")),
                            now: Date.init),
                        session: session)
                }
                let controller = PrompterController(
                    deps: PrompterController.Dependencies(
                        makeCommand: { [weak self] key in
                            var extra = ["MLAUD_LLM_KEY": key, "PYTHONUNBUFFERED": "1"]
                            if let dir = ProcessInfo.processInfo.environment["MLAUD_PROMPTER_DIR"], !dir.isEmpty {
                                extra["MLAUD_PROMPTER_DIR"] = dir
                            }
                            if let budget = self?.settingsStore.materialsBudgetTokens {
                                extra["MLAUD_MATERIALS_BUDGET"] = String(budget)
                            }
                            return WorkerCommand(
                                pythonExecutable: self?.pythonExecutable ?? URL(fileURLWithPath: "/usr/bin/python3"),
                                workerDirectory: self?.workerDirectory ?? URL(fileURLWithPath: "."),
                                inboxFolder: self?.folderStore.inboxFolder ?? URL(fileURLWithPath: "/tmp"),
                                additionalPythonPath: self?.additionalPythonPath ?? [],
                                extraEnvironment: extra,
                                module: "mlaud_worker.prompter")
                        },
                        paths: paths,
                        now: Date.init),
                    session: session)
                return controller
            },
            connections: llmConnections,
            secrets: secrets,
            settings: settingsStore,
            paths: paths
        )
        let controller = CallController(deps: deps)
        controller.onChange = { [weak self, weak controller] snapshot in
            guard let self, let controller else { return }
            self.applyCallSnapshot(snapshot, from: controller)
        }
        controller.onNotify = { [weak self] title, body in
            self?.notify(title: title, body: body)
        }
        call = controller
        return controller
    }

    /// Снимок звонка → модель. `publish()` сканирует inbox и карантин и пересобирает меню,
    /// а уровни приходят на каждый кусок звука — публикуем только по фазе, секунде и распознавателю.
    private func applyCallSnapshot(_ snapshot: CallSnapshot, from controller: CallController) {
        let previous = model.call
        model.call = snapshot
        syncCallApps(from: controller)
        if snapshot.phase == .done, previous.phase != .done {
            reloadRecordings()
        }
        if previous.phase != snapshot.phase
            || Int(previous.elapsed) != Int(snapshot.elapsed)
            || previous.recognizer != snapshot.recognizer {
            publish()
        }
    }

    /// Кандидаты контроллера → модель; приложение по умолчанию из настроек — пока выбора нет.
    private func syncCallApps(from controller: CallController) {
        model.callApps = controller.candidates
        if controller.selectedApp == nil, model.call.phase == .ready,
           let wanted = settings.callAppBundleID,
           let candidate = controller.candidates.first(where: { $0.bundleID == wanted }) {
            controller.selectedApp = candidate
        }
        model.callAppPID = controller.selectedApp?.pid
    }

    /// ⌘R в главном меню — по контексту (D5): в «Суфлёре» старт/стоп звонка, иначе обработка.
    @objc func primaryAction() {
        switch (model.section, model.call.phase) {
        case (.prompter, .ready): startCall()
        case (.prompter, .running): stopCall()
        default: processNow()
        }
    }

    /// Объясняем ловушку ad-hoc подписи. Просто «дайте разрешение» здесь бесполезно:
    /// в списке галка обычно уже стоит — но у старого файла, а не у нового.
    private func presentAccessibilityHelp() {
        mainWindow.show(section: .dictation)
        let alert = NSAlert()
        alert.messageText = "Диктовке нужен «Универсальный доступ»"
        alert.informativeText = """
            Без него набранный текст некуда печатать: система молча выбрасывает \
            нажатия, которые шлёт приложение.

            Если MLaud в списке уже стоит с галкой — она относится к прошлой сборке. \
            Подпись у приложения ad-hoc, поэтому разрешение привязано к конкретному \
            файлу, а после обновления файл другой. Удалите строку MLaud кнопкой «−» \
            и добавьте /Applications/MLaud.app заново.
            """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func onWake() { autoProcess() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Действия экранов

extension AppDelegate: AppCommands {
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку, откуда забирать аудиофайлы (inbox)"
        if let current = folderStore.inboxFolder { panel.directoryURL = current }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            folderStore.inboxFolder = url
            status = .idle
            restartWatcher()
            // Приёмник держит папку в своей конфигурации: без перезапуска принятое
            // с телефона уедет в прежний inbox, за которым уже никто не следит.
            restartPhoneSync()
            publish()
            autoProcess()
        }
    }

    func openWorkerLogFile() {
        if !fm.fileExists(atPath: workerLogURL.path) {
            try? fm.createDirectory(at: workerLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: workerLogURL.path, contents: nil)
        }
        NSWorkspace.shared.open(workerLogURL)
    }

    func openResultsFolder() {
        try? fm.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(resultsDirectory)
    }

    /// «Повторить» из карантина: файл возвращается в inbox, конвейер подхватывает его сам.
    func retryQuarantine(_ url: URL) {
        guard let inbox = folderStore.inboxFolder else {
            model.toast = "Сначала выбери папку inbox"
            return
        }
        var target = inbox.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            target = inbox.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent)-\(stamp).\(url.pathExtension)")
        }
        do {
            try fm.moveItem(at: url, to: target)
            model.toast = "Файл вернулся в inbox"
            publish()
            autoProcess()
        } catch {
            notify(title: "MLaud — карантин", body: "Не удалось вернуть файл: \(error.localizedDescription)")
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func requestMicrophone() {
        // Чек-лист звонка ведёт контроллер: повторный prepare() в .ready заново спрашивает разрешение
        // и обновляет снимок; голый requestPermission обновил бы только экран «Диктовка».
        if let controller = call, controller.session.snapshot.phase == .ready {
            controller.prepare()
            return
        }
        AudioCapture.requestPermission { [weak self] _ in
            DispatchQueue.main.async { self?.publish() }
        }
    }

    /// Возврат из «Конфиденциальности и безопасности»: разрешение на микрофон macOS выдаёт без
    /// перезапуска, а чек-лист узнаёт о нём только при повторной проверке.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let controller = call, controller.session.snapshot.phase == .ready,
              case .denied = controller.session.snapshot.microphone else { return }
        controller.prepare()
    }

    func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openDictationLog() {
        let url = DictationLog.url
        if !fm.fileExists(atPath: url.path) {
            DictationLog.write("журнал открыт до первой записи")
        }
        // Запись асинхронная — даём ей долететь, иначе откроется пустой файл.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSWorkspace.shared.open(url)
        }
    }

    func markNotificationRead(_ id: UUID) {
        notifications.markRead(id: id)
        publish()
    }

    func markAllNotificationsRead() {
        notifications.markAllRead()
        publish()
    }

    func clearNotifications() {
        let alert = NSAlert()
        alert.messageText = "Очистить журнал уведомлений?"
        alert.informativeText = "Записи будут удалены безвозвратно."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notifications.clear()
        publish()
    }

    func pairing() -> PairingInfo? {
        do {
            let code = try phoneSync.pairingCode()
            let manual = try phoneSync.manualCode()
            return PairingInfo(qr: PhoneSyncController.qrImage(for: code), manualCode: manual)
        } catch {
            notify(title: "MLaud — iPhone", body: "Не удалось подготовить код связи: \(error)")
            return nil
        }
    }

    func regeneratePairing() {
        let alert = NSAlert()
        alert.messageText = "Сменить код сопряжения?"
        alert.informativeText = "Все уже связанные телефоны придётся связать заново."
        alert.addButton(withTitle: "Сменить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try phoneSync.regeneratePairing()
            restartPhoneSync()
            model.toast = "Код связи сменён"
        } catch {
            notify(title: "MLaud — iPhone", body: "Не удалось сменить код: \(error)")
        }
    }

    /// «Проверить» в настройках доставки: `python -m mlaud_worker.telegram --test` с теми же
    /// переменными окружения, что получает worker.
    func testTelegram() {
        guard settings.telegramTest != .running else { return }
        settings.telegramTest = .running
        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folderStore.inboxFolder ?? serviceDirectory,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: settingsStore.workerEnvironment(),
            module: "mlaud_worker.telegram",
            moduleArguments: ["--test"]
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = command.makeProcess()
            let stderr = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            var outcome: SettingsModel.TelegramTest
            do {
                try process.run()
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    outcome = .ok
                } else {
                    let reason = errorText.split(separator: "\n").last.map(String.init) ?? "код \(process.terminationStatus)"
                    outcome = .failed(String(reason.prefix(120)))
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async { self?.settings.telegramTest = outcome }
        }
    }

    func showStyleguide() { mainWindow.show(section: .styleguide) }

    // Суфлёр (этап 3, §4.6)

    @objc func startCallSetup() {
        openMainWindow()
        model.section = .prompter
        if !previewOnly { refreshSelfVoice() }
        guard let controller = callController() else { return }
        // «Начать звонок…» из меню при показанном итоге прошлого звонка — закрыть его и готовить новый.
        if controller.session.snapshot.phase == .done {
            controller.dismiss()
        }
        if controller.session.snapshot.phase == .idle {
            controller.prepare()
            model.callBriefSlug = nil
        }
        syncCallApps(from: controller)
    }

    /// Во время звонка диктовку можно только остановить (S1: третий канал не измерен).
    private var dictationToggleAllowed: Bool {
        model.call.phase != .running || dictation?.state == .listening
    }

    @objc func startCall() {
        guard let controller = callController(), controller.session.snapshot.canStart else { return }
        // Звонок и диктовка не живут вместе: два захвата микрофона и три сессии распознавателя.
        switch dictation?.state ?? .off {
        case .listening:
            DictationLog.write("диктовка закрыта: начинается звонок")
            dictation?.toggle()
        case .starting:
            notify(title: "MLaud — суфлёр", body: "диктовка ещё запускается — дождитесь её или выключите, затем «Старт»")
            return
        case .off:
            break
        }
        controller.start()
    }

    @objc func stopCall() {
        guard let controller = call, controller.session.snapshot.phase == .running else { return }
        controller.stop()
    }

    func dismissCall() {
        call?.dismiss()
        reloadRecordings()
    }

    func refreshCallApps() {
        guard let controller = callController() else { return }
        controller.refreshApps()
        // `onChange` молчит, если чек-лист не изменился, — список кандидатов подтягиваем сами.
        for delay in [0.7, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.syncCallApps(from: controller)
            }
        }
    }

    func selectCallApp(_ pid: Int32?) {
        guard let controller = callController() else { return }
        controller.selectedApp = pid.flatMap { id in controller.candidates.first { $0.pid == id } }
        settings.callAppBundleID = controller.selectedApp?.bundleID
        model.callAppPID = controller.selectedApp?.pid
    }

    func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Согласие на «Запись экрана» выдаётся процессу при запуске (poc/appaudio/RESULT.md:78) — нужен перезапуск.
    func relaunchApp() {
        guard Bundle.main.bundleIdentifier != nil else {
            notify(title: "MLaud — суфлёр", body: "dev-запуск без бандла: перезапустите `swift run` руками")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            notify(title: "MLaud — суфлёр", body: "Не удалось перезапустить: \(error.localizedDescription)")
        }
    }

    func openCallFolder(_ callID: String) {
        let folder = CallStore.folder(root: promptRoot, callID: callID)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // Суфлёр — этап 4 (§4.5)

    private func refreshConnections() {
        settings.connections = llmConnections.all
        settings.defaultConnectionID = llmConnections.defaultID
        settings.connectionHasKey = Dictionary(uniqueKeysWithValues:
            settings.connections.map { ($0.id, prompterSecrets.secret(for: $0.id) != nil) })
    }

    /// Перечитать бриф и материалы из папки (правки руками в Finder видны при открытии).
    private func openBriefEditor(slug: String) {
        do {
            let brief = try BriefStore.load(paths: prompterPaths, slug: slug)
            model.editingBriefSlug = slug
            model.editingBrief = brief
            model.prompterView = .editor
            refreshMaterials(slug: slug)
        } catch {
            notify(title: "MLaud — суфлёр", body: "Бриф не открылся: \(error.localizedDescription)")
        }
    }

    private func refreshMaterials(slug: String) {
        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folderStore.inboxFolder ?? serviceDirectory,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: ["MLAUD_MATERIALS_BUDGET": String(settingsStore.materialsBudgetTokens)],
            module: "mlaud_worker.prompter",
            moduleArguments: ["--materials", prompterPaths.materials(slug: slug).path,
                              "--budget", String(settingsStore.materialsBudgetTokens)])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = command.makeProcess()
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            var report: MaterialsReport?
            if (try? process.run()) != nil {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                report = try? MaterialsReport.decode(data)
            }
            DispatchQueue.main.async {
                self?.model.editingMaterials = report
            }
        }
    }

    /// ⌘N: меню шаблонов; валидно только в разделе «Суфлёр» (validateMenuItem).
    @objc func newBriefMenu() {
        let menu = NSMenu()
        let titles = ["продажа": "sale", "интервью": "interview", "переговоры": "negotiation",
                      "встреча": "meeting", "свой": "custom"]
        for (index, pair) in titles.enumerated() {
            let item = NSMenuItem(title: "Бриф: \(pair.key)", action: #selector(newBriefPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        if let event = NSApp.currentEvent, let window = NSApp.keyWindow {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            _ = event
            _ = window
        }
    }

    @objc private func newBriefPicked(_ sender: NSMenuItem) {
        let slugs = ["sale", "interview", "negotiation", "meeting", "custom"]
        guard sender.tag < slugs.count else { return }
        newBrief(template: slugs[sender.tag])
    }

    func newBrief(template: String) {
        let alert = NSAlert()
        alert.messageText = "Название брифа"
        alert.informativeText = "Например: «Интервью — Иван Петров, senior BA»"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Создать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            let slug = try BriefStore.newBrief(paths: prompterPaths, template: template, title: title)
            reloadRecordings()
            openBriefEditor(slug: slug)
        } catch {
            notify(title: "MLaud — суфлёр", body: "Бриф не создался: \(error.localizedDescription)")
        }
    }

    func openBrief(slug: String) {
        openBriefEditor(slug: slug)
    }

    func saveBrief(_ brief: Brief) {
        guard let slug = model.editingBriefSlug else { return }
        do {
            try BriefStore.save(brief, paths: prompterPaths, slug: slug)
        } catch {
            notify(title: "MLaud — суфлёр", body: "Бриф не сохранился: \(error.localizedDescription)")
        }
    }

    func duplicateBrief(slug: String) {
        do {
            let copy = try BriefStore.duplicate(paths: prompterPaths, slug: slug)
            reloadRecordings()
            openBriefEditor(slug: copy)
        } catch {
            notify(title: "MLaud — суфлёр", body: "Копия не создалась: \(error.localizedDescription)")
        }
    }

    func deleteBrief(slug: String) {
        let alert = NSAlert()
        alert.messageText = "Удалить бриф?"
        alert.informativeText = "Папка брифа и материалы будут удалены. Звонки останутся."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BriefStore.delete(paths: prompterPaths, slug: slug)
            model.prompterView = .list
            reloadRecordings()
        } catch {
            notify(title: "MLaud — суфлёр", body: "Бриф не удалился: \(error.localizedDescription)")
        }
    }

    func openBriefFolder(slug: String) {
        NSWorkspace.shared.open(prompterPaths.briefs.appendingPathComponent(slug, isDirectory: true))
    }

    func addMaterials(slug: String, urls: [URL]) {
        for url in urls {
            _ = try? BriefStore.addMaterial(paths: prompterPaths, slug: slug, from: url)
        }
        refreshMaterials(slug: slug)
    }

    func addMaterialFromRecordings(slug: String, base: String) {
        // «Из записей»: копия .txt транскрипта из архива (FR-12.5) — запись за месяц до base.
        let candidates = [resultsDirectory.appendingPathComponent(String(base.prefix(7))).appendingPathComponent(base + ".txt")]
        for url in candidates where fm.fileExists(atPath: url.path) {
            _ = try? BriefStore.addMaterial(paths: prompterPaths, slug: slug, from: url)
        }
        refreshMaterials(slug: slug)
    }

    func removeMaterial(slug: String, name: String) {
        try? BriefStore.removeMaterial(paths: prompterPaths, slug: slug, name: name)
        refreshMaterials(slug: slug)
    }

    func startCall(brief slug: String) {
        startCallSetup()
        guard let controller = callController(),
              let brief = try? BriefStore.load(paths: prompterPaths, slug: slug) else { return }
        model.callBriefSlug = slug
        controller.prepare(brief: (slug, brief))
        if controller.session.snapshot.canStart {
            startCall()
        }
    }

    /// Выбор брифа в чек-листе перед стартом: суфлёр включается только с брифом.
    func prepareCallBrief(_ slug: String?) {
        guard let controller = callController() else { return }
        model.callBriefSlug = slug
        // Открытый редактор старше диска: сохранение с дебаунсом могло не успеть —
        // «Начать звонок» сразу после смены режима не должен получить старый brief.md.
        if let slug {
            let brief = (slug == model.editingBriefSlug ? model.editingBrief : nil)
                ?? (try? BriefStore.load(paths: prompterPaths, slug: slug))
            if let brief {
                controller.prepare(brief: (slug, brief))
                return
            }
        }
        controller.prepare(brief: nil)
    }

    func setCallMode(_ mode: String) {
        callController()?.setMode(mode)
    }

    @objc func requestHint() {
        call?.requestHint()
    }

    func relabelTranscriptLine(id: Int) {
        call?.relabelLine(id: id)
    }

    @objc func markLastTranscriptLineThem() {
        call?.markLastLineThem()
    }

    func togglePrompterPause() {
        guard let prompter = call?.prompter else { return }
        prompterPaused.toggle()
        prompter.setPaused(prompterPaused)
    }

    func pinCard(_ id: String) {
        call?.session.apply(.pin(id))
    }

    func unpinCard(_ id: String) {
        call?.session.apply(.unpin(id))
    }

    func dismissCard(_ id: String) {
        call?.session.apply(.dismissCard(id))
    }

    func requestDetail(_ id: String) {
        call?.requestDetail(id)
    }

    func copyCard(_ id: String) {
        let card = model.call.prompter.cards.first { $0.id == id }
            ?? model.call.prompter.pinned.first { $0.id == id }
        guard let card else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.text, forType: .string)
        model.toast = "Скопировано"
    }

    func setAgenda(item: String, status: AgendaStatus) {
        call?.session.apply(.agendaManual(item: item, status: status))
    }

    func addNote(_ text: String) {
        guard !text.isEmpty else { return }
        call?.session.apply(.note(text))
    }

    func cancelOutcome() {
        call?.cancelOutcome()
    }

    func openOutcome(callID: String) {
        model.prompterView = .outcome(callID: callID)
        model.section = .prompter
    }

    func saveOutcome(callID: String, markdown: String) {
        CallStore.writeOutcomeMarkdown(root: promptRoot, callID: callID, text: markdown)
    }

    /// Опоздавшие итоги — руками (§3.7): `telegram send <outcome.md>` с ключами доставки.
    func sendOutcomeToTelegram(callID: String) {
        let outcome = CallStore.folder(root: promptRoot, callID: callID).appendingPathComponent("outcome.md")
        guard fm.fileExists(atPath: outcome.path) else {
            model.toast = "Итогов нет — звонок без суфлёра"
            return
        }
        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folderStore.inboxFolder ?? serviceDirectory,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: settingsStore.workerEnvironment(),
            module: "mlaud_worker.telegram",
            moduleArguments: ["send", outcome.path])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = command.makeProcess()
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            _ = try? process.run()
            process.waitUntilExit()
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                self?.model.toast = ok ? "Отправлено" : ("Не отправилось: " + text.prefix(80))
            }
        }
    }

    func copyOutcome(callID: String) {
        if let outcome = CallStore.readOutcome(root: promptRoot, callID: callID) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(outcome.markdown, forType: .string)
            model.toast = "Скопировано"
        }
    }

    @objc func toggleCompactPanel() {
        if compactPanel == nil { compactPanel = CompactPanelController(model: model) }
        compactPanel?.toggle()
    }

    func saveProfile(_ text: String) {
        try? text.write(to: prompterPaths.profile, atomically: true, encoding: .utf8)
    }

    func saveConnection(_ c: LLMConnection, key: String?) {
        llmConnections.save(c)
        settings.connectionCheck[c.id] = .idle      // старый «нет ключа» не должен висеть
        if let key = key?.trimmingCharacters(in: .whitespaces) {
            if key.isEmpty {
                try? prompterSecrets.setSecret(nil, for: c.id)
            } else {
                do { try prompterSecrets.setSecret(key, for: c.id) } catch {
                    notify(title: "MLaud — суфлёр", body: "Keychain: \(error.localizedDescription)")
                }
            }
        }
        refreshConnections()
    }

    func removeConnection(id: String) {
        llmConnections.remove(id: id)
        try? prompterSecrets.setSecret(nil, for: id)
        refreshConnections()
    }

    func setDefaultConnection(id: String) {
        llmConnections.defaultID = id
        refreshConnections()
    }

    /// «Проверить» (FR-12.13): `--check` с ключом подключения, stdin — JSON подключения.
    func checkConnection(id: String) {
        guard let connection = llmConnections.all.first(where: { $0.id == id }) else { return }
        guard let key = prompterSecrets.secret(for: id) else {
            let present = (prompterSecrets as? KeychainStore)?.contains(id) ?? false
            settings.connectionCheck[id] = .failed(present
                ? "ключ сохранён, но Keychain не отдаёт его — напишите в MLaud"
                : "нет ключа — «Изменить…» → поле «Ключ» → «Сохранить»")
            return
        }
        settings.connectionCheck[id] = .running
        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folderStore.inboxFolder ?? serviceDirectory,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: ["MLAUD_LLM_KEY": key, "PYTHONUNBUFFERED": "1"],
            module: "mlaud_worker.prompter",
            moduleArguments: ["--check"])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = command.makeProcess()
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            var result: SettingsModel.ConnectionCheck = .failed("не запустился")
            if (try? process.run()) != nil {
                stdin.fileHandleForWriting.write(Self.checkPayload(connection))
                stdin.fileHandleForWriting.closeFile()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
                    if obj["ok"] as? Bool == true {
                        result = .ok(ttftMs: (obj["ttft_ms"] as? NSNumber)?.intValue ?? 0)
                    } else {
                        result = .failed((obj["message"] as? String) ?? "ошибка")
                    }
                } else {
                    result = .failed("код \(process.terminationStatus)")
                }
            }
            DispatchQueue.main.async { self?.settings.connectionCheck[id] = result }
        }
    }

    /// JSON для --check: connection как в start, null вместо отсутствующих цен.
    private static func checkPayload(_ connection: LLMConnection) -> Data {
        var reasoning: Any = NSNull()
        switch connection.reasoning {
        case .off: reasoning = ["enabled": false]
        case .effort(let e): reasoning = ["effort": e]
        case .unspecified: break
        }
        let payload: [String: Any] = ["connection": [
            "base_url": connection.baseURL,
            "model": connection.model,
            "reasoning": reasoning,
            "price_per_mtok": [
                "in": connection.price.input.map { $0 as Any } ?? NSNull(),
                "out": connection.price.output.map { $0 as Any } ?? NSNull(),
                "cached": connection.price.cached.map { $0 as Any } ?? NSNull()],
        ] as [String: Any]]
        return (try! JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])) + Data("\n".utf8)
    }
}

// MARK: - Пункты меню

extension AppDelegate: NSMenuItemValidation {
    /// С этим протоколом доступность всех пунктов с целью `AppDelegate` решается здесь,
    /// ручные `isEnabled` в `buildMenu` система перекрывает.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(primaryAction):
            switch (model.section, model.call.phase) {
            case (.prompter, .ready):
                item.title = "Старт звонка"
                return model.call.canStart
            case (.prompter, .running):
                item.title = "Стоп звонка"
                return true
            default:
                item.title = "Обработать сейчас"
                return folderStore.hasInboxFolder && !isProcessing && !previewOnly
            }
        case #selector(processNow):
            return folderStore.hasInboxFolder && !isProcessing && !previewOnly
        case #selector(toggleDictation):
            return dictation?.state != .starting && dictationToggleAllowed
        case #selector(startCallSetup):
            return !previewOnly && model.call.phase != .running && model.call.phase != .finishing
        case #selector(stopCall):
            return model.call.phase == .running
        default:
            return true
        }
    }
}

// MARK: - Отклик на системный баннер

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Баннер должен появляться, даже когда приложение активно (открыто главное окно):
    /// иначе сообщение исчезает вовсе.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Клик по баннеру открывает раздел «Уведомления» на этой же записи.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let id = UUID(uuidString: response.notification.request.identifier)
        DispatchQueue.main.async { [weak self] in
            guard let self, isDefaultAction else { return }
            // «Готово · к разметке: 2 голоса» ведёт сразу в «Голоса», остальное — в журнал.
            if let id, self.notifications.record(id: id)?.action == "voices" {
                self.notifications.markRead(id: id)
                self.mainWindow.show(section: .voices)
                // Раздел мог быть открыт и до баннера: onAppear тогда не сработает.
                self.voices.reload()
            } else {
                self.model.revealNotification = id
                self.mainWindow.show(section: .notifications)
            }
            self.publish()
        }
        completionHandler()
    }
}
