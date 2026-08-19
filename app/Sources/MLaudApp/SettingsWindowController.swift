import AppKit
import MLaudCore

/// Окно настроек: Telegram, модель, автозапуск, мгновенная обработка, уведомления.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private let onSave: () -> Void

    private let tokenField = NSTextField()
    private let chatField = NSTextField()
    private let modelPopup = NSPopUpButton()
    private let loginCheck = NSButton(checkboxWithTitle: "Автозапуск при входе в систему", target: nil, action: nil)
    private let watchCheck = NSButton(checkboxWithTitle: "Мгновенная обработка новых файлов", target: nil, action: nil)
    private let notifyCheck = NSButton(checkboxWithTitle: "Системные уведомления о готовности/ошибке", target: nil, action: nil)
    private let diarizeCheck = NSButton(checkboxWithTitle: "Диаризация (определять спикеров, pyannote)", target: nil, action: nil)
    private let dictationCheck = NSButton(checkboxWithTitle: "Диктовка по горячей клавише", target: nil, action: nil)
    private lazy var hotKeyRecorder = HotKeyRecorder(combo: settings.dictationHotKey)
    private let hfField = NSTextField()
    private let speakersField = NSTextField()
    private let devicePopup = NSPopUpButton()

    init(settings: SettingsStore, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Настройки MLaud"
        super.init(window: window)
        window.delegate = self
        buildUI()
        load()
        // Высота подбирается под содержимое, а не задаётся числом: подсказки переносятся
        // на разное число строк, и на глаз выставленные 470 точек накрывали кнопками
        // последние ряды сетки.
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize
            window.setContentSize(NSSize(width: max(760, fitting.width),
                                         height: max(480, fitting.height)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tokenField.placeholderString = "123456:ABC… (пусто — берётся из .env)"
        chatField.placeholderString = "напр. 123456789"
        hfField.placeholderString = "hf_… (нужен для диаризации)"
        speakersField.placeholderString = "0 = авто"
        modelPopup.addItems(withTitles: SettingsStore.availableModels)
        devicePopup.addItems(withTitles: SettingsStore.availableDevices)

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }
        // Серая подсказка в третьей колонке — поясняет назначение поля.
        func hint(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.isSelectable = false
            l.maximumNumberOfLines = 0   // было 2 — длинные подсказки обрезались на полуслове
            l.preferredMaxLayoutWidth = 250
            return l
        }

        let grid = NSGridView(views: [
            [label("Telegram токен:"), tokenField, hint("токен бота для доставки .txt в Telegram")],
            [label("Telegram chat_id:"), chatField, hint("кому слать (твой Telegram chat id)")],
            [label("Модель:"), modelPopup, hint("rnnt — точнее (рекоменд.); ctc — быстрее, чуть менее точно")],
            [NSGridCell.emptyContentView, loginCheck, hint("работает только для приложения в /Applications")],
            [NSGridCell.emptyContentView, watchCheck, hint("реагировать на новый файл сразу; иначе проход раз в 120 с")],
            [NSGridCell.emptyContentView, notifyCheck],
            [NSGridCell.emptyContentView, dictationCheck, hint("наговорить текст прямо в активное поле ввода; спросит микрофон и «Универсальный доступ»")],
            [label("Сочетание клавиш:"), hotKeyRecorder, hint("кликни и нажми нужное сочетание; Esc — отмена")],
            [NSGridCell.emptyContentView, diarizeCheck, hint("метки спикеров (pyannote); требует HF-токен ниже")],
            [label("HF-токен:"), hfField, hint("для скачивания весов pyannote с huggingface.co; нужен один раз")],
            [label("Число спикеров:"), speakersField, hint("0 = определить авто; N — если точно знаешь сколько говорящих")],
            [label("Устройство диаризации:"), devicePopup, hint("mps — GPU Apple, ~22× быстрее; cpu — запасной")],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            // Кнопки всегда ниже сетки: без этой связи они рисовались поверх неё.
            buttons.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
        ])
    }

    private func load() {
        tokenField.stringValue = settings.telegramToken
        chatField.stringValue = settings.telegramChatID
        modelPopup.selectItem(withTitle: settings.modelType)
        watchCheck.state = settings.instantWatch ? .on : .off
        notifyCheck.state = settings.notificationsEnabled ? .on : .off
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        diarizeCheck.state = settings.diarizeEnabled ? .on : .off
        dictationCheck.state = settings.dictationEnabled ? .on : .off
        hfField.stringValue = settings.hfToken
        speakersField.stringValue = settings.numSpeakers > 0 ? String(settings.numSpeakers) : ""
        devicePopup.selectItem(withTitle: settings.diarizeDevice)
    }

    @objc private func save() {
        settings.telegramToken = tokenField.stringValue
        settings.telegramChatID = chatField.stringValue
        settings.modelType = modelPopup.titleOfSelectedItem ?? SettingsStore.defaultModel
        settings.instantWatch = watchCheck.state == .on
        settings.notificationsEnabled = notifyCheck.state == .on
        settings.diarizeEnabled = diarizeCheck.state == .on
        settings.dictationEnabled = dictationCheck.state == .on
        settings.dictationHotKey = hotKeyRecorder.combo
        settings.hfToken = hfField.stringValue
        settings.numSpeakers = Int(speakersField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        settings.diarizeDevice = devicePopup.titleOfSelectedItem ?? SettingsStore.defaultDevice

        if settings.diarizeEnabled && settings.hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Диаризация включена без HF-токена"
            alert.informativeText = "Для диаризации (pyannote) нужен HuggingFace-токен. Без него файлы будут обработаны без меток спикеров."
            alert.alertStyle = .warning
            alert.runModal()
        }

        let wantLogin = loginCheck.state == .on
        if wantLogin != LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(wantLogin)
            } catch {
                presentLoginError(error)
            }
        }

        if settings.notificationsEnabled {
            UserNotifier.requestAuthorization()
        }

        onSave()
        close()
    }

    @objc private func cancel() { close() }

    private func presentLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не удалось изменить автозапуск"
        alert.informativeText = "\(error.localizedDescription)\n\nАвтозапуск работает только для установленного приложения (из .dmg в /Applications)."
        alert.alertStyle = .warning
        alert.runModal()
        loginCheck.state = LoginItem.isEnabled ? .on : .off
    }
}
