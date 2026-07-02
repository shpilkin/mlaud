import AppKit
import MLaudCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let folderStore = FolderStore()
    private let settings = SettingsStore()
    private let scanner = InboxScanner()

    private var status: ProcessingStatus = .noFolder { didSet { refresh() } }
    private var isProcessing = false
    private var sweepTimer: Timer?
    private var watcher: FolderWatcher?
    private var debounceWork: DispatchWorkItem?
    private var settingsWindow: SettingsWindowController?

    private let fm = FileManager.default

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
        return URL(fileURLWithPath: "/Users/<user>/my_projects/mlaud/poc/.venv/bin/python")
    }
    private var workerDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["MLAUD_WORKER_DIR"] { return URL(fileURLWithPath: p) }
        if let res = bundledResources {
            let bundled = res.appendingPathComponent("worker")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: "/Users/<user>/my_projects/mlaud/worker")
    }
    /// Доп. PYTHONPATH: вложенный site-packages (в бандле), иначе пусто (dev-venv самодостаточен).
    private var additionalPythonPath: [URL] {
        if let res = bundledResources {
            let sp = res.appendingPathComponent("site-packages")
            if fm.fileExists(atPath: sp.path) { return [sp] }
        }
        return []
    }
    private var resultsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ASR/ASROutput/AllOutputs")
    }
    /// Лог worker'а: stdout+stderr Python-процесса. Без него ошибки невидимы (exit-код без причины).
    private var workerLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ASR/service/worker.log")
    }

    /// В очереди на доставку есть недоставленные транскрипты (сеть падала при обработке).
    /// Такие досылаются воркером при следующем прогоне — даже если inbox пуст.
    private var hasPendingDeliveries: Bool {
        let url = workerLogURL.deletingLastPathComponent()
            .appendingPathComponent("pending_delivery.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return false }
        return !arr.isEmpty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status = folderStore.hasInboxFolder ? .idle : .noFolder

        if settings.notificationsEnabled {
            UserNotifier.requestAuthorization()
        }

        // Пробуждение из сна → разобрать накопленное.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        // Периодический «подметающий» проход (страховка от пропущенных событий/iCloud-лага).
        sweepTimer = Timer.scheduledTimer(
            timeInterval: 120, target: self, selector: #selector(autoProcess),
            userInfo: nil, repeats: true
        )
        restartWatcher()
        refresh()
        autoProcess()  // подхватить файлы, накопившиеся пока приложение не работало
    }

    // MARK: - UI

    private func refresh() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MLaud")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusLine = NSMenuItem(title: status.menuTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let folderPath = folderStore.inboxFolder?.path ?? "—"
        let folderLine = NSMenuItem(title: "Папка: \(folderPath)", action: nil, keyEquivalent: "")
        folderLine.isEnabled = false
        menu.addItem(folderLine)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Выбрать папку…",
                                action: #selector(chooseFolder), keyEquivalent: "o"))

        let processItem = NSMenuItem(title: "Обработать сейчас",
                                     action: #selector(processNow), keyEquivalent: "r")
        processItem.isEnabled = folderStore.hasInboxFolder && !isProcessing
        menu.addItem(processItem)

        menu.addItem(NSMenuItem(title: "Открыть папку результатов",
                                action: #selector(openResults), keyEquivalent: ""))

        menu.addItem(NSMenuItem(title: "Открыть лог…",
                                action: #selector(openWorkerLogFile), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Настройки…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

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

    // MARK: - Actions

    @objc private func chooseFolder() {
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
            autoProcess()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in
                self?.restartWatcher()  // применить изменения мгновенной обработки
                self?.refresh()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.center()
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func autoProcess() {
        guard folderStore.hasInboxFolder, !isProcessing else { return }
        guard let folder = folderStore.inboxFolder else { return }
        // Запускаем воркер, если есть новые файлы ИЛИ висит недоставленное в очереди.
        guard !scanner.readyAudioFiles(in: folder).isEmpty || hasPendingDeliveries else { return }
        processNow()
    }

    @objc private func processNow() {
        guard let folder = folderStore.inboxFolder, !isProcessing else { return }
        let pending = scanner.readyAudioFiles(in: folder)
        // Прогон «только досыл» (файлов нет, но очередь непуста) — допустим.
        let flushOnly = pending.isEmpty
        guard !pending.isEmpty || hasPendingDeliveries else { status = .idle; return }

        isProcessing = true
        status = .processing(current: 0, total: pending.count)

        let command = WorkerCommand(
            pythonExecutable: pythonExecutable,
            workerDirectory: workerDirectory,
            inboxFolder: folder,
            additionalPythonPath: additionalPythonPath,
            extraEnvironment: settings.workerEnvironment()
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
                if flushOnly, case .done = result {
                    // Тихий досыл очереди: без уведомления «Готово: 0» и без дебаунс-
                    // ретригера (иначе при падающей сети получим busy-loop). Повтор —
                    // штатным sweep-таймером раз в 120 с.
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
        guard settings.notificationsEnabled else { return }
        switch result {
        case .done:
            UserNotifier.notify(title: "MLaud — готово",
                                body: "Обработано файлов: \(count)")
        case .error(let message):
            UserNotifier.notify(title: "MLaud — ошибка", body: message)
        default:
            break
        }
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

    @objc private func openWorkerLogFile() {
        if !fm.fileExists(atPath: workerLogURL.path) {
            try? fm.createDirectory(at: workerLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: workerLogURL.path, contents: nil)
        }
        NSWorkspace.shared.open(workerLogURL)
    }

    @objc private func openResults() {
        try? FileManager.default.createDirectory(
            at: resultsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(resultsDirectory)
    }

    @objc private func onWake() { autoProcess() }

    @objc private func quit() { NSApp.terminate(nil) }
}
