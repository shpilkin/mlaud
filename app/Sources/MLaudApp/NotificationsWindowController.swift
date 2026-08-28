import AppKit
import MLaudCore

/// Окно журнала уведомлений: список сообщений, полный текст выбранного.
///
/// Нужно потому, что баннер в углу экрана исчезает сам и по клику ничего не
/// открывает, а длинное сообщение об ошибке в него не помещается целиком.
final class NotificationsWindowController: NSWindowController {
    private let history: NotificationHistory
    private let onChange: () -> Void

    private var records: [AppNotification] = []
    private let table = NSTableView()
    private let detail = NSTextView()
    private let emptyLabel = NSTextField(labelWithString:
        "Пусто. Здесь будет всё, о чём приложение сообщало баннером в углу экрана.")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    init(history: NotificationHistory, onChange: @escaping () -> Void) {
        self.history = history
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Уведомления MLaud"
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        buildUI()
        reload(revealing: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        detail.isEditable = false
        // Выделять текст обязательно: сообщение об ошибке чаще всего нужно скопировать.
        detail.isSelectable = true
        detail.font = .systemFont(ofSize: 12)
        detail.textContainerInset = NSSize(width: 6, height: 6)
        detail.drawsBackground = false
        // Перенос по ширине окна: без этого длинная строка ошибки уходит вправо
        // за край и читается только до обрыва.
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        let readAll = NSButton(title: "Пометить всё прочитанным",
                               target: self, action: #selector(markAllRead))
        readAll.bezelStyle = .rounded
        let clear = NSButton(title: "Очистить", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let close = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let buttons = NSStackView(views: [readAll, clear, NSView(), close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(detailScroll)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),

            detailScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            detailScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            detailScroll.heightAnchor.constraint(equalToConstant: 110),

            buttons.topAnchor.constraint(equalTo: detailScroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Данные

    /// Перечитать журнал. `revealing` — запись, которую надо показать и открыть
    /// (клик по баннеру приводит именно сюда).
    func reload(revealing id: UUID?) {
        // Выделение держим за записью, а не за номером строки: пришедшее сообщение
        // сдвигает список вниз, и номер начинает указывать на чужой текст.
        let selected = table.selectedRow >= 0 && table.selectedRow < records.count
            ? records[table.selectedRow].id : nil
        records = history.records
        table.reloadData()
        emptyLabel.isHidden = !records.isEmpty

        if let target = id ?? selected,
           let row = records.firstIndex(where: { $0.id == target }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else if selected == nil, id == nil, !records.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        // Выбор мог не измениться номером строки — текст обновляем в любом случае.
        showDetail()
    }

    private func showDetail() {
        let row = table.selectedRow
        guard row >= 0, row < records.count else {
            detail.string = records.isEmpty ? "" : "Выберите сообщение в списке."
            return
        }
        let record = records[row]
        detail.string = "\(record.title)\n\(record.body)"
    }

    @objc private func markAllRead() {
        history.markAllRead()
        reload(revealing: nil)
        onChange()
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Очистить журнал уведомлений?"
        alert.informativeText = "Записи будут удалены безвозвратно."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.clear()
        reload(revealing: nil)
        onChange()
    }

    @objc private func closeWindow() { close() }
}

// MARK: - Таблица

extension NotificationsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? RowView
            ?? RowView(identifier: identifier)
        view.configure(with: records[row], stamp: Self.stamp)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail()
        let row = table.selectedRow
        guard row >= 0, row < records.count, !records[row].isRead else { return }
        // Открыл — значит прочитал: иначе счётчик непрочитанных врёт.
        history.markRead(id: records[row].id)
        records[row].isRead = true
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(integer: 0))
        onChange()
    }
}

/// Строка списка: время, заголовок, первая строка текста. Непрочитанное — жирным с точкой.
private final class RowView: NSTableCellView {
    private let dot = NSTextField(labelWithString: "●")
    private let time = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        dot.font = .systemFont(ofSize: 9)
        dot.textColor = .controlAccentColor
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byTruncatingTail
        title.lineBreakMode = .byTruncatingTail
        // Иначе длинный заголовок распирает строку за край колонки вместо многоточия.
        for label in [title, body] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let head = NSStackView(views: [dot, time, title])
        head.orientation = .horizontal
        head.spacing = 6
        let stack = NSStackView(views: [head, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(with record: AppNotification, stamp: DateFormatter) {
        dot.isHidden = record.isRead
        time.stringValue = stamp.string(from: record.date)
        title.stringValue = record.title
        title.font = .systemFont(ofSize: 12, weight: record.isRead ? .regular : .semibold)
        body.stringValue = record.body.replacingOccurrences(of: "\n", with: " ")
    }
}
