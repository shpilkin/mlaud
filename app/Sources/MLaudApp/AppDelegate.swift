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
    private var dictation: DictationController?
    private var hotKey: HotKey?
    /// Не удалось занять сочетание: показываем прямо в меню, иначе диктовка выглядит
    /// просто сломанной.
    private var hotKeyFailed = false

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
        // dev-фолбэк (`swift run` из каталога app/): путь относительно репозитория.
        // Своё расположение задаётся через переменную окружения MLAUD_PY.
        return URL(fileURLWithPath: "../poc/.venv/bin/python")
    }
    private var workerDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["MLAUD_WORKER_DIR"] { return URL(fileURLWithPath: p) }
        if let res = bundledResources {
            let bundled = res.appendingPathComponent("worker")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        // dev-фолбэк (`swift run` из каталога app/): путь относительно репозитория.
        // Своё расположение задаётся через переменную окружения MLAUD_WORKER_DIR.
        return URL(fileURLWithPath: "../worker")
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
        restartDictation()
        refresh()
        autoProcess()  // подхватить файлы, накопившиеся пока приложение не работало
    }

    // MARK: - UI

    private func refresh() {
        if let button = statusItem.button {
            // Во время диктовки иконка другая — иначе не видно, что микрофон открыт.
            let symbol = dictation?.state == .off || dictation == nil ? "waveform" : "mic.fill"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MLaud")
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

        if settings.dictationEnabled {
            menu.addItem(.separator())
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
                    title: "  \(settings.dictationHotKey.display) занято — выбери другое в настройках",
                    action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
            }
            menu.addItem(NSMenuItem(title: "Журнал диктовки…",
                                    action: #selector(openDictationLog), keyEquivalent: ""))
            if !TextInserter.isTrusted {
                menu.addItem(NSMenuItem(title: "Выдать «Универсальный доступ»…",
                                        action: #selector(openAccessibilitySettings),
                                        keyEquivalent: ""))
            }
        }

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
                self?.restartWatcher()    // применить изменения мгновенной обработки
                self?.restartDictation()  // ... и включение/выключение диктовки
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
        // не меняются, а настройки живут в своём объекте. Так у контроллера нет ссылки
        // на владельца и не нужен разбор «а вдруг self уже нет».
        let python = pythonExecutable
        let workerDir = workerDirectory
        let extraPath = additionalPythonPath
        let inbox = folderStore.inboxFolder ?? fm.homeDirectoryForCurrentUser
        let settings = self.settings
        let controller = DictationController {
            var env = settings.workerEnvironment()
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
            self?.refresh()
        }
        controller.onNeedsAccessibility = { [weak self] in
            DictationLog.write("ОШИБКА: нет «Универсального доступа»")
            self?.presentAccessibilityHelp()
        }
        controller.onError = { [weak self] message in
            DictationLog.write("ОШИБКА: \(message)")
            guard let self, self.settings.notificationsEnabled else { return }
            UserNotifier.notify(title: "MLaud — диктовка", body: message)
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
            if settings.notificationsEnabled {
                UserNotifier.notify(
                    title: "MLaud — диктовка",
                    body: "\(combo.display) занято другим приложением; выбери другое сочетание в настройках")
            }
        }
    }

    @objc private func toggleDictation() {
        DictationLog.write("переключение диктовки из состояния \(dictation?.state.debugName ?? "нет контроллера")")
        dictation?.toggle()
    }

    /// Объясняем ловушку ad-hoc подписи. Просто «дайте разрешение» здесь бесполезно:
    /// в списке галка обычно уже стоит — но у старого файла, а не у нового.
    private func presentAccessibilityHelp() {
        NSApp.activate(ignoringOtherApps: true)
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openDictationLog() {
        let url = DictationLog.url
        if !fm.fileExists(atPath: url.path) {
            DictationLog.write("журнал открыт до первой записи")
        }
        // Запись асинхронная — даём ей долететь, иначе откроется пустой файл.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func onWake() { autoProcess() }

    @objc private func quit() {
        dictation?.shutdown()  // резидентная модель держит ~1.6 ГБ — отпускаем явно
        NSApp.terminate(nil)
    }
}
