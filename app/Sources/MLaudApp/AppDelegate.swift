import AppKit
import AVFoundation
import MLaudCore
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
    private var dictation: DictationController?
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
    /// Карантин упавших файлов — тот же путь, что `Config.default().failed` у worker'а.
    private var failedDirectory: URL { home.appendingPathComponent("ASR/Failed") }
    /// Служебная папка приложения: логи, состояние, данные приёма с телефона.
    private var serviceDirectory: URL { home.appendingPathComponent("ASR/service") }
    /// Лог worker'а: stdout+stderr Python-процесса. Без него ошибки невидимы (exit-код без причины).
    private var workerLogURL: URL { serviceDirectory.appendingPathComponent("worker.log") }

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
        publish()
        autoProcess()  // подхватить файлы, накопившиеся пока приложение не работало
    }

    /// Клик по иконке в Dock, пока окно закрыто, но приложение ещё `.regular`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.shutdown()  // резидентная модель держит ~1.6 ГБ — отпускаем явно
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
            // Во время диктовки иконка другая — иначе не видно, что микрофон открыт.
            let symbol = dictation?.state == .off || dictation == nil ? "waveform" : "mic.fill"
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
    func reloadRecordings() {
        let index = RecordingIndex(root: resultsDirectory,
                                   speakersRoot: serviceDirectory.appendingPathComponent("speakers"))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recordings = index.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.recordings = recordings
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

        // Замыкание держит значения, а не AppDelegate: пути за время жизни приложения
        // не меняются, а настройки живут в своём объекте.
        let python = pythonExecutable
        let workerDir = workerDirectory
        let extraPath = additionalPythonPath
        let inbox = folderStore.inboxFolder ?? fm.homeDirectoryForCurrentUser
        let store = settingsStore
        let controller = DictationController {
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
        DictationLog.write("переключение диктовки из состояния \(dictation?.state.debugName ?? "нет контроллера")")
        dictation?.toggle()
        publish()
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
        AudioCapture.requestPermission { [weak self] _ in
            DispatchQueue.main.async { self?.publish() }
        }
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
