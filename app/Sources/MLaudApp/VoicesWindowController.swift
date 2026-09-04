import AppKit
import AVFoundation
import MLaudCore
import UniformTypeIdentifiers

/// Окно «Голоса»: разметка спикеров по карточкам кластеров и управление базой.
///
/// Просмотрщика транскрипта у приложения нет, поэтому размечаем не «по абзацам», а по
/// кластерам: worker сохранил вектор, цитату и клипы каждого (сайдкар, §6.2 фичи), и
/// имя ставится на кластер целиком — так же, как «ко всем абзацам этого спикера» у Plaud.
final class VoicesWindowController: NSWindowController {
    private let store: SpeakerSidecarStore
    private let runner: VoicesRunner
    private let onChange: () -> Void

    private var recordings: [SpeakerRecording] = []
    private var listing: VoiceListing?
    private var selectedURL: URL?
    private var busy = false { didSet { render() } }

    private let tabs = NSTabView()
    private let recordingsTable = NSTableView()
    private let cards = NSStackView()
    private let cardsScroll = NSScrollView()
    private let header = NSTextField(labelWithString: "")
    private let channelPopup = NSPopUpButton()
    private let showHiddenCheck = NSButton(checkboxWithTitle: "показывать убранные", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let relabelButton = NSButton(title: "Переподписать транскрипт", target: nil, action: nil)
    private let resendButton = NSButton(title: "Отправить заново", target: nil, action: nil)
    private let prepareButton = NSButton(title: "Разметить старую запись…", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Убрать из списка", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var prepareQueue: [URL] = []
    private var prepareTotal = 0

    private let peopleTable = NSTableView()
    private var peopleRows: [PeopleRow] = []
    private let renameButton = NSButton(title: "Переименовать…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Удалить", target: nil, action: nil)
    private let revealButton = NSButton(title: "Показать в разметке", target: nil, action: nil)
    /// Куда перейти после подготовки записи из архива (образец без сайдкара).
    private var pendingReveal: (source: String, label: String)?

    private var player: AVAudioPlayer?
    private var playing: (label: String, index: Int)?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    private static let channels: [(title: String, value: String)] = [
        ("телефон", "phone"), ("ВКС", "vks"), ("другое", "other"),
    ]

    init(store: SpeakerSidecarStore, runner: VoicesRunner, onChange: @escaping () -> Void) {
        self.store = store
        self.runner = runner
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Голоса"
        window.minSize = NSSize(width: 760, height: 440)
        super.init(window: window)
        buildUI()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let label = NSTabViewItem(identifier: "label")
        label.label = "Разметить"
        label.view = buildLabelTab()
        tabs.addTabViewItem(label)

        let people = NSTabViewItem(identifier: "people")
        people.label = "Люди"
        people.view = buildPeopleTab()
        tabs.addTabViewItem(people)
    }

    private func buildLabelTab() -> NSView {
        let root = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rec"))
        column.resizingMask = .autoresizingMask
        recordingsTable.addTableColumn(column)
        recordingsTable.headerView = nil
        recordingsTable.rowHeight = 46
        recordingsTable.style = .inset
        recordingsTable.dataSource = self
        recordingsTable.delegate = self
        let left = NSScrollView()
        left.documentView = recordingsTable
        left.hasVerticalScroller = true
        left.autohidesScrollers = true
        left.borderType = .bezelBorder
        left.translatesAutoresizingMaskIntoConstraints = false

        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let channelLabel = NSTextField(labelWithString: "Канал записи:")
        channelLabel.textColor = .secondaryLabelColor
        channelLabel.font = .systemFont(ofSize: 11)
        for c in Self.channels { channelPopup.addItem(withTitle: c.title) }
        channelPopup.selectItem(at: 2)
        channelPopup.font = .systemFont(ofSize: 11)
        channelPopup.controlSize = .small
        showHiddenCheck.font = .systemFont(ofSize: 11)
        showHiddenCheck.controlSize = .small
        showHiddenCheck.target = self
        showHiddenCheck.action = #selector(toggleHidden)
        let head = NSStackView(views: [header, NSView(), showHiddenCheck, channelLabel, channelPopup])
        head.orientation = .horizontal
        head.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false

        cards.orientation = .vertical
        cards.alignment = .width
        cards.spacing = 8
        // Документ скролла ведём рамкой (layoutCards), а не констрейнтами к clip view:
        // с ними стек при первом показе вставал справа по своей ширине и вставал на
        // место только после полной перекладки окна (смена вкладки).
        cards.translatesAutoresizingMaskIntoConstraints = true
        let clip = FlippedClipView()
        clip.documentView = cards
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
        cardsScroll.contentView = clip
        cardsScroll.hasVerticalScroller = true
        cardsScroll.autohidesScrollers = true
        cardsScroll.drawsBackground = false
        cardsScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        relabelButton.target = self
        relabelButton.action = #selector(relabel)
        relabelButton.bezelStyle = .rounded
        relabelButton.toolTip = "Записать текущие имена в .txt и .srt на диске. После каждой разметки "
            + "это делается само; кнопка — если файлы правили отдельно."
        resendButton.target = self
        resendButton.action = #selector(resend)
        resendButton.bezelStyle = .rounded
        resendButton.toolTip = "Отправить .txt этой записи в Telegram ещё раз, уже с именами."
        let done = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        // Без клавиши по умолчанию: Enter в поле имени иначе закрывал окно, а не сохранял.
        prepareButton.target = self
        prepareButton.action = #selector(prepareOld)
        prepareButton.bezelStyle = .rounded
        forgetButton.target = self
        forgetButton.action = #selector(forgetRecording)
        forgetButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [prepareButton, forgetButton, spinner, statusLabel, NSView(),
                                         relabelButton, resendButton, done])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        for v in [left, head, cardsScroll, emptyLabel, footer] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            left.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            left.widthAnchor.constraint(equalToConstant: 230),

            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            head.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            cardsScroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            cardsScroll.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            cardsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            cardsScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: cardsScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: cardsScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: cardsScroll.widthAnchor, constant: -40),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        return root
    }

    private func buildPeopleTab() -> NSView {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("person"))
        column.resizingMask = .autoresizingMask
        peopleTable.addTableColumn(column)
        peopleTable.headerView = nil
        peopleTable.rowHeight = 24
        peopleTable.style = .inset
        peopleTable.dataSource = self
        peopleTable.delegate = self
        peopleTable.target = self
        peopleTable.doubleAction = #selector(revealSample)
        let scroll = NSScrollView()
        scroll.documentView = peopleTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        renameButton.target = self
        renameButton.action = #selector(renamePerson)
        renameButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealSample)
        revealButton.bezelStyle = .rounded
        revealButton.toolTip = "Открыть кластер этого образца во вкладке «Разметить» (то же — двойной клик)"
        let refresh = NSButton(title: "Обновить", target: self, action: #selector(reloadAction))
        refresh.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString:
            "Образцы — векторы голоса из размеченных записей, только на этом Mac. "
            + "Удаление человека удаляет все его образцы. Двойной клик по образцу открывает его "
            + "кластер в разметке.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [renameButton, deleteButton, revealButton, NSView(), refresh])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        for v in [scroll, hint, buttons] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        return root
    }

    // MARK: - Данные

    /// Перечитать сайдкары с диска и базу людей (через worker).
    func reload() {
        recordings = store.recent()
        if let selectedURL, !recordings.contains(where: { $0.url == selectedURL }) {
            self.selectedURL = nil
        }
        if selectedURL == nil { selectedURL = recordings.first?.url }
        recordingsTable.reloadData()
        if let row = recordings.firstIndex(where: { $0.url == selectedURL }) {
            recordingsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        render()
        runner.run(["list", "--json"]) { [weak self] result in
            guard let self, result.ok,
                  let listing = try? VoiceListing.parse(Data(result.stdout.utf8)) else { return }
            self.listing = listing
            self.rebuildPeopleRows()
            self.render()
        }
    }

    private var selected: SpeakerRecording? {
        recordings.first { $0.url == selectedURL }
    }

    private var channel: String {
        Self.channels[max(0, channelPopup.indexOfSelectedItem)].value
    }

    /// Подпись состояния записи: сколько ждёт, всё названо или размечать нечего.
    static func statusText(_ s: SpeakerSidecar) -> String {
        let pending = s.pendingCount
        if pending > 0 { return "\(pending) к разметке" }
        if s.hasLabelableClusters { return "все названы" }
        return "нечего размечать: речи меньше \(Int(s.minSpeech)) с"
    }

    private func render() {
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        prepareButton.isEnabled = !busy
        forgetButton.isEnabled = !busy && selected != nil
        for view in cards.arrangedSubviews { cards.removeArrangedSubview(view); view.removeFromSuperview() }

        guard let rec = selected else {
            header.stringValue = ""
            emptyLabel.stringValue = recordings.isEmpty
                ? "Пока нечего размечать. Карточки появляются у записей, обработанных с включённым "
                  + "«Подписывать известные голоса» (Настройки), и у старых записей — по кнопке "
                  + "«Разметить старую запись…»."
                : "Выбери запись слева."
            emptyLabel.isHidden = false
            relabelButton.isEnabled = false
            resendButton.isEnabled = false
            layoutCards()
            return
        }
        emptyLabel.isHidden = true
        let s = rec.sidecar
        header.stringValue = "\(s.base) · \(Self.stamp.string(from: rec.date)) · \(Self.statusText(s))"
        relabelButton.isEnabled = !busy
        resendButton.isEnabled = !busy && !s.txt.isEmpty
        let hiddenCount = s.clusters.filter(\.hidden).count
        showHiddenCheck.isHidden = hiddenCount == 0
        showHiddenCheck.title = "показывать убранные (\(hiddenCount))"
        let showHidden = showHiddenCheck.state == .on
        for cluster in s.clusters where !cluster.hidden || showHidden {
            let card = ClusterCardView(cluster: cluster, minSpeech: s.minSpeech,
                                       people: listing?.names ?? [], enabled: !busy)
            card.onPlay = { [weak self] index in self?.togglePlay(rec: rec, cluster: cluster, index: index) }
            card.onAction = { [weak self] action in self?.apply(action, to: cluster, in: rec) }
            addCard(card)
            if let playing, playing.label == cluster.label, player?.isPlaying == true {
                card.setPlaying(index: playing.index)
            }
        }
        if let error = s.clipsError {
            let note = NSTextField(wrappingLabelWithString: "Образцы аудио не нарезаны: \(error)")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            addCard(note)
        }
        layoutCards()
    }

    /// Карточка во всю ширину стека. Одного `alignment = .width` не хватает: карточка
    /// уже содержимого вставала по своей ширине к правому краю.
    private func addCard(_ view: NSView) {
        cards.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cards.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cards.trailingAnchor),
        ])
    }

    @objc private func clipResized() { layoutCards() }
    @objc private func toggleHidden() { render() }

    /// Ширина документа — по clip view, высота — по содержимому.
    private func layoutCards() {
        let width = cardsScroll.contentView.bounds.width
        guard width > 0 else { return }
        cards.frame = NSRect(x: 0, y: 0, width: width, height: cards.fittingSize.height)
        cards.layoutSubtreeIfNeeded()
    }

    private func apply(_ action: ClusterCardView.Action, to cluster: SpeakerCluster,
                       in rec: SpeakerRecording) {
        let base = ["assign", rec.url.path, cluster.label]
        switch action {
        case .assign(let name):
            run(base + ["--name", name, "--channel", channel])
        case .confirm:
            guard let name = cluster.effectiveMatch?.name else { return }
            run(base + ["--name", name, "--channel", channel])
        case .reject: run(base + ["--reject"])
        case .none: run(base + ["--none"])
        case .mixed: run(base + ["--mixed"])
        case .delete: run(base + ["--delete"])
        case .restore: run(base + ["--restore"])
        }
    }

    private func askName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Имя или инициалы"
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func run(_ args: [String], then: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        stopPlayback()
        busy = true
        runner.run(args) { [weak self] result in
            guard let self else { return }
            self.busy = false
            if !result.ok {
                self.statusLabel.stringValue = ""
                let alert = NSAlert()
                alert.messageText = "Не получилось"
                alert.informativeText = result.message
                alert.alertStyle = .warning
                alert.runModal()
            } else if ["resend", "relabel", "prepare", "forget"].contains(args.first ?? "") {
                // Последняя строка вывода worker'а — «переподписано строк: N», «отправлено: …».
                self.statusLabel.stringValue = result.stdout
                    .split(separator: "\n").last.map(String.init) ?? ""
            }
            self.reload()
            self.onChange()
            then?(result.ok)
        }
    }

    // MARK: - Старые записи и удаление из списка

    /// Записи, обработанные до включения идентификации, сайдкара не имеют. Кнопка гонит
    /// выбранные файлы из архива через worker заново (транскрипт + сайдкар, без доставки).
    @objc private func prepareOld() {
        let panel = NSOpenPanel()
        panel.message = "Транскрипт будет сделан заново с именами из базы. В Telegram ничего не уходит."
        panel.prompt = "Разметить"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ASR/Processed/AllRecords")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        prepareQueue = panel.urls
        prepareTotal = panel.urls.count
        prepareNext()
    }

    private func prepareNext() {
        guard !prepareQueue.isEmpty else { return }
        let url = prepareQueue.removeFirst()
        let n = prepareTotal - prepareQueue.count
        statusLabel.stringValue = "Обрабатываю «\(url.deletingPathExtension().lastPathComponent)» "
            + "(\(n)/\(prepareTotal)) — минуту-две…"
        run(["prepare", url.path]) { [weak self] ok in
            guard let self else { return }
            if ok, let rec = self.recordings.first(where: { $0.sidecar.source == url.lastPathComponent }) {
                self.selectedURL = rec.url
                if let row = self.recordings.firstIndex(where: { $0.url == rec.url }) {
                    self.recordingsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.render()
                if let pending = self.pendingReveal, pending.source == url.lastPathComponent {
                    self.pendingReveal = nil
                    self.highlight(label: pending.label)
                }
            }
            self.prepareNext()
        }
    }

    /// Убрать запись из разметки: удаляется её каталог с клипами и векторами.
    /// Транскрипт и уже сохранённые голоса не трогаются.
    @objc private func forgetRecording() {
        guard let rec = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Убрать «\(rec.sidecar.base)» из списка?"
        alert.informativeText = "Образцы аудио и векторы этой записи будут удалены. "
            + "Транскрипт и голоса, уже сохранённые в базу, останутся."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Убрать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectedURL = nil
        run(["forget", rec.url.path])
    }

    // MARK: - Действия

    @objc private func relabel() {
        guard let rec = selected else { return }
        run(["relabel", rec.url.path])
    }

    @objc private func resend() {
        guard let rec = selected else { return }
        run(["resend", rec.url.path])
    }

    @objc private func reloadAction() { reload() }

    @objc private func closeWindow() {
        stopPlayback()
        close()
    }

    // MARK: - Прослушивание

    private func togglePlay(rec: SpeakerRecording, cluster: SpeakerCluster, index: Int) {
        let clips = rec.clipURLs(for: cluster)
        guard index >= 0, index < clips.count else { return }
        if let playing, playing.label == cluster.label, playing.index == index,
           player?.isPlaying == true {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: clips[index]) else { return }
        p.delegate = self
        player = p
        playing = (cluster.label, index)
        p.play()
        card(for: cluster.label)?.setPlaying(index: index)
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
        for case let card as ClusterCardView in cards.arrangedSubviews { card.setPlaying(index: nil) }
    }

    private func card(for label: String) -> ClusterCardView? {
        cards.arrangedSubviews.compactMap { $0 as? ClusterCardView }.first { $0.label == label }
    }

    // MARK: - Люди

    enum PeopleRow {
        case person(VoicePerson)
        case sample(VoicePerson, VoiceSample)
    }

    private func rebuildPeopleRows() {
        peopleRows = []
        for person in listing?.people ?? [] {
            peopleRows.append(.person(person))
            for sample in person.samples { peopleRows.append(.sample(person, sample)) }
        }
        peopleTable.reloadData()
        updatePeopleButtons()
    }

    private func updatePeopleButtons() {
        let row = peopleTable.selectedRow
        guard row >= 0, row < peopleRows.count, !busy else {
            renameButton.isEnabled = false
            deleteButton.isEnabled = false
            revealButton.isEnabled = false
            return
        }
        switch peopleRows[row] {
        case .person:
            renameButton.isEnabled = true
            revealButton.isEnabled = false
            deleteButton.title = "Удалить человека"
        case .sample:
            renameButton.isEnabled = false
            revealButton.isEnabled = true
            deleteButton.title = "Удалить образец"
        }
        deleteButton.isEnabled = true
    }

    // MARK: - Из образца в разметку

    @objc private func revealSample() {
        let row = peopleTable.clickedRow >= 0 ? peopleTable.clickedRow : peopleTable.selectedRow
        guard row >= 0, row < peopleRows.count, case .sample(_, let sample) = peopleRows[row] else { return }
        reveal(source: sample.sourceFile, label: sample.label)
    }

    /// Показать кластер записи во вкладке «Разметить». Сайдкара нет (запись обработана до
    /// включения разметки или убрана) — предложить подготовить её из архива.
    @discardableResult
    func reveal(source: String, label: String) -> Bool {
        if let rec = recordings.first(where: { $0.sidecar.source == source }) {
            tabs.selectTabViewItem(withIdentifier: "label")
            selectedURL = rec.url
            if let row = recordings.firstIndex(where: { $0.url == rec.url }) {
                recordingsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            render()
            highlight(label: label)
            return true
        }
        guard !busy else { return false }
        guard let audio = Self.findInArchive(source) else {
            let alert = NSAlert()
            alert.messageText = "Записи «\(source)» нет в архиве"
            alert.informativeText = "Образец остаётся в базе, но открыть его кластер негде."
            alert.runModal()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "У записи «\(source)» нет карточек"
        alert.informativeText = "Она обработана до включения разметки. Подготовить её сейчас? "
            + "Транскрипт будет сделан заново с именами из базы, это минуту-две."
        alert.addButton(withTitle: "Подготовить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        pendingReveal = (source, label)
        tabs.selectTabViewItem(withIdentifier: "label")
        prepareQueue = [audio]
        prepareTotal = 1
        prepareNext()
        return true
    }

    private static func findInArchive(_ name: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ASR/Processed/AllRecords")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name { return url }
        return nil
    }

    private func highlight(label: String) {
        guard let card = card(for: label) else { return }
        layoutCards()
        card.scrollToVisible(card.bounds)
        card.flash()
    }

    @objc private func renamePerson() {
        let row = peopleTable.selectedRow
        guard row >= 0, case .person(let person) = peopleRows[row] else { return }
        guard let name = askName(title: "Переименовать",
                                 message: "Новое имя для «\(person.name)» — в базе и в размеченных записях.",
                                 initial: person.name), name != person.name else { return }
        run(["rename", person.name, name])
    }

    @objc private func deleteSelected() {
        let row = peopleTable.selectedRow
        guard row >= 0, row < peopleRows.count else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        switch peopleRows[row] {
        case .person(let person):
            alert.messageText = "Удалить «\(person.name)» и \(person.samples.count) образц.?"
            alert.informativeText = "Голос перестанет узнаваться. Транскрипты не меняются."
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            run(["remove", "--person", person.name])
        case .sample(let person, let sample):
            alert.messageText = "Удалить образец «\(person.name)» из \(sample.sourceFile)?"
            alert.informativeText = "Остальные образцы этого человека остаются."
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            run(["remove", "--sample", sample.id])
        }
    }

    // MARK: - Дымовая проверка (main.swift --smoke-voices)

    /// Окно нельзя прогнать автоматикой без «Универсального доступа», поэтому сборку
    /// карточек и путь действия проверяем отсюда: реальный сайдкар, реальный worker.
    func smokeReport() -> String {
        let clipWidth = Int(cardsScroll.contentView.bounds.width.rounded())
        let widths = cards.arrangedSubviews.map { Int($0.frame.width.rounded()) }
        return "recordings=\(recordings.count) cards=\(cards.arrangedSubviews.count) "
        + "cardsWidth=\(Int(cards.frame.width.rounded()))/\(clipWidth) cardWidths=\(widths) "
        + "people=\(listing?.people.count ?? -1) rows=\(peopleRows.count) "
        + "pending=\(selected?.sidecar.pendingCount ?? -1) busy=\(busy) header=«\(header.stringValue)»"
    }

    /// Переход из образца: вкладка «Разметить», нужная запись, карточка кластера на месте.
    func smokeReveal(source: String, label: String) -> Bool {
        guard reveal(source: source, label: label) else { return false }
        return tabs.selectedTabViewItem?.identifier as? String == "label"
            && selected?.sidecar.source == source
            && card(for: label) != nil
    }

    /// «Оставить без имени» для первого кластера к разметке — тот же путь, что клик в карточке.
    func smokeDismissFirstPending() -> Bool {
        guard let rec = selected,
              let cluster = rec.sidecar.clusters.first(where: {
                  $0.needsAttention(minSpeech: rec.sidecar.minSpeech) })
        else { return false }
        apply(.none, to: cluster, in: rec)
        return true
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static func mmss(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - Таблицы

extension VoicesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === recordingsTable ? recordings.count : peopleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === recordingsTable {
            let id = NSUserInterfaceItemIdentifier("recRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? RecordingRowView
                ?? RecordingRowView(identifier: id)
            view.configure(recordings[row], stamp: Self.stamp)
            return view
        }
        let id = NSUserInterfaceItemIdentifier("personRow")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makePersonCell(id)
        switch peopleRows[row] {
        case .person(let p):
            view.textField?.stringValue = "\(p.name) — \(p.samples.count) \(Self.plural(p.samples.count, "образец", "образца", "образцов")), с \(p.created.prefix(10))"
            view.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
        case .sample(_, let s):
            let channel = Self.channels.first { $0.value == s.channel }?.title ?? s.channel
            view.textField?.stringValue = "      \(Int(s.speechSec)) c · \(channel) · \(s.sourceFile) · \(s.added.prefix(10))"
            view.textField?.font = .systemFont(ofSize: 11)
        }
        return view
    }

    private func makePersonCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === recordingsTable {
            let row = recordingsTable.selectedRow
            selectedURL = row >= 0 && row < recordings.count ? recordings[row].url : nil
            stopPlayback()
            render()
        } else {
            updatePeopleButtons()
        }
    }
}

extension VoicesWindowController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopPlayback()
    }
}

// MARK: - Строка записи

private final class RecordingRowView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        for l in [title, subtitle] { l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let stack = NSStackView(views: [title, subtitle])
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

    func configure(_ rec: SpeakerRecording, stamp: DateFormatter) {
        title.stringValue = rec.sidecar.base
        let pending = rec.sidecar.pendingCount
        subtitle.stringValue = stamp.string(from: rec.date) + " · "
            + VoicesWindowController.statusText(rec.sidecar)
        subtitle.textColor = pending > 0 ? .systemOrange : .secondaryLabelColor
    }
}

// MARK: - Карточка кластера

/// Одна карточка: фрагменты для прослушивания, кто это по мнению базы, поле имени.
///
/// Три состояния: свёрнута (человек убрал кластер: «без имени» / «несколько голосов»),
/// короткий кластер (послушать можно, имя не ставится — FR-8.9), рабочая (поле имени,
/// подтверждение автоузнавания, «ещё»).
private final class ClusterCardView: NSView, NSComboBoxDelegate {
    enum Action {
        case assign(String)   // имя из поля или из списка
        case confirm          // «Да, он» — имя из автоузнавания
        case reject           // «Нет» / «Не он»
        case none             // оставить без имени
        case mixed            // несколько голосов
        case delete           // корзина: убрать из списка
        case restore          // вернуть свёрнутый кластер к разметке
    }

    var onPlay: ((Int) -> Void)?
    var onAction: ((Action) -> Void)?

    let label: String
    private let assigned: String?
    private var clipButtons: [NSButton] = []
    private var clipTitles: [String] = []
    private let combo = NSComboBox()
    private var nameRow: NSStackView?

    init(cluster: SpeakerCluster, minSpeech: Double, people: [String], enabled: Bool) {
        label = cluster.label
        assigned = cluster.assigned
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let long = cluster.isLong(minSpeech: minSpeech) && cluster.hasEmbedding
        let collapsed = cluster.isCollapsed
        // Поле имени есть у всех несвёрнутых: короткому имя идёт только в транскрипт,
        // отпечаток в базу — только длинному (FR-8.9).
        let active = !collapsed

        // Фрагменты: по кнопке на каждый, с таймкодом — чтобы выбирать, что слушать.
        let clipsRow = NSStackView()
        clipsRow.orientation = .horizontal
        clipsRow.spacing = 4
        if cluster.clips.isEmpty {
            let b = NSButton(title: "▶", target: nil, action: nil)
            b.bezelStyle = .rounded
            b.isEnabled = false
            clipsRow.addArrangedSubview(b)
        }
        for (i, _) in cluster.clips.enumerated() {
            let stamp = i < cluster.clipStarts.count
                ? VoicesWindowController.mmss(cluster.clipStarts[i]) : "\(i + 1)"
            let b = NSButton(title: "▶ \(stamp)", target: self, action: #selector(playTapped(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            b.isEnabled = enabled
            clipButtons.append(b)
            clipTitles.append(stamp)
            clipsRow.addArrangedSubview(b)
        }
        clipsRow.setContentHuggingPriority(.required, for: .horizontal)
        clipsRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString:
            "\(cluster.display) · \(VoicesWindowController.mmss(cluster.speechSec)) речи · с "
            + VoicesWindowController.mmss(cluster.firstAt))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = long && !collapsed ? .labelColor : .secondaryLabelColor
        let quoted = cluster.quote.isEmpty ? "" : "«\(cluster.quote)»"
        let second: String
        if collapsed {
            second = quoted
        } else if long {
            second = quoted
        } else {
            second = "речи меньше \(VoicesWindowController.mmss(minSpeech)): имя пойдёт только в "
                + "транскрипт, отпечаток в базу не снять"
                + (quoted.isEmpty ? "" : " · \(quoted)")
        }
        let subtitle = NSTextField(labelWithString: second)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        for l in [title, subtitle] { l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Справа: что думает база, и кнопки подтверждения.
        let right = NSStackView()
        right.orientation = .horizontal
        right.spacing = 6
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        if collapsed {
            // Состояние видно плашкой, а не подписью мелким шрифтом; карандаш возвращает
            // к разметке, корзина убирает совсем.
            if cluster.hidden {
                right.addArrangedSubview(Self.badge("убран из списка", color: .systemGray))
            } else if cluster.mixed {
                right.addArrangedSubview(Self.badge("смесь / неразборчиво", color: .systemOrange))
            } else {
                right.addArrangedSubview(Self.badge("без имени", color: .systemGray))
            }
            right.addArrangedSubview(Self.iconButton("pencil", tip: "Вернуть к разметке",
                                                     target: self, action: #selector(restoreTapped),
                                                     enabled: enabled))
            if !cluster.hidden {
                right.addArrangedSubview(Self.iconButton("trash", tip: "Убрать фрагмент из списка",
                                                         target: self, action: #selector(deleteTapped),
                                                         enabled: enabled))
            }
        } else {
            if let assigned = cluster.assigned {
                right.addArrangedSubview(Self.badge("✓ \(assigned)", color: .systemGreen))
                // Карандаш: имя уже стоит, поле показываем только по просьбе.
                right.addArrangedSubview(Self.iconButton("pencil", tip: "Изменить имя",
                                                         target: self, action: #selector(editTapped),
                                                         enabled: enabled))
            } else if let m = cluster.effectiveMatch {
                let score = String(format: "%.2f", m.score)
                right.addArrangedSubview(Self.badge(m.sure ? "✓ \(m.name) · \(score)" : "\(m.name) (?) · \(score)",
                                                    color: m.sure ? .systemGreen : .systemOrange))
                if !m.sure {
                    let yes = NSButton(title: "Да, он", target: self, action: #selector(confirmTapped))
                    yes.bezelStyle = .rounded
                    yes.controlSize = .small
                    yes.isEnabled = enabled
                    right.addArrangedSubview(yes)
                }
                let no = NSButton(title: m.sure ? "Не он" : "Нет", target: self, action: #selector(rejectTapped))
                no.bezelStyle = .rounded
                no.controlSize = .small
                no.isEnabled = enabled
                right.addArrangedSubview(no)
            }
            // Корзина: фрагмент не нужен в списке. Клипы остаются до ретенции, вернуть можно.
            right.addArrangedSubview(Self.iconButton("trash", tip: "Убрать фрагмент из списка",
                                                     target: self, action: #selector(deleteTapped),
                                                     enabled: enabled))
        }

        var rowViews: [NSView] = [clipsRow, text]
        if !right.arrangedSubviews.isEmpty { rowViews.append(right) }
        let row1 = NSStackView(views: rowViews)
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 10

        let column = NSStackView(views: [row1])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        if active {
            // Поле имени: пишешь новое или выбираешь из списка. Enter, выбор из списка
            // и «Сохранить» — одно и то же действие.
            combo.usesDataSource = false
            combo.addItems(withObjectValues: people)
            combo.completes = true
            combo.placeholderString = people.isEmpty ? "Кто это? Имя или инициалы"
                                                     : "Кто это? Имя или выбери из списка"
            combo.stringValue = cluster.assigned ?? ""
            combo.delegate = self
            combo.target = self
            combo.action = #selector(comboEntered)
            combo.isEnabled = enabled
            let save = NSButton(title: "Сохранить", target: self, action: #selector(saveTapped))
            save.bezelStyle = .rounded
            save.isEnabled = enabled
            // Два выхода из разметки — видимыми кнопками, а не в меню: их ищут.
            let mixed = NSButton(title: "Смесь / неразборчиво", target: self, action: #selector(mixedTapped))
            let none = NSButton(title: "Без имени", target: self, action: #selector(noneTapped))
            for b in [mixed, none] {
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.isEnabled = enabled
            }
            mixed.toolTip = "В кластере слышно нескольких или не разобрать: в базу не идёт, остаётся «Спикер N»."
            none.toolTip = "Случайный голос: имени не будет, со счётчика снимается."
            let row2 = NSStackView(views: [combo, save, NSView(), mixed, none])
            row2.orientation = .horizontal
            row2.spacing = 8
            combo.widthAnchor.constraint(equalToConstant: 280).isActive = true
            column.addArrangedSubview(row2)
            // Уже подписанному поле не нужно, пока не нажали карандаш.
            row2.isHidden = cluster.assigned != nil
            nameRow = row2
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Подсветить рамку на пару секунд: сюда перешли из вкладки «Люди».
    func flash() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.layer?.borderColor = NSColor.separatorColor.cgColor
            self?.layer?.borderWidth = 1
        }
    }

    /// Какой фрагмент сейчас играет (nil — ни один): у него «■» вместо «▶».
    func setPlaying(index: Int?) {
        for (i, b) in clipButtons.enumerated() {
            b.title = (i == index ? "■ " : "▶ ") + clipTitles[i]
        }
    }

    private static func iconButton(_ symbol: String, tip: String, target: AnyObject,
                                   action: Selector, enabled: Bool) -> NSButton {
        let b = NSButton(title: "", target: target, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.toolTip = tip
        b.isEnabled = enabled
        return b
    }

    @objc private func editTapped() {
        guard let row = nameRow else { return }
        row.isHidden.toggle()
        if !row.isHidden { combo.window?.makeFirstResponder(combo) }
        // Высота карточки изменилась — стеку выше надо пересчитать документ скролла.
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: superview?.superview)
    }

    @objc private func deleteTapped() { onAction?(.delete) }

    private static func badge(_ text: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func submit(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != assigned else { return }
        onAction?(.assign(name))
    }

    @objc private func playTapped(_ sender: NSButton) { onPlay?(sender.tag) }
    @objc private func saveTapped() { submit(combo.stringValue) }
    @objc private func comboEntered() { submit(combo.stringValue) }
    @objc private func confirmTapped() { onAction?(.confirm) }
    @objc private func rejectTapped() { onAction?(.reject) }
    @objc private func restoreTapped() { onAction?(.restore) }

    @objc private func mixedTapped() { onAction?(.mixed) }
    @objc private func noneTapped() { onAction?(.none) }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let name = combo.objectValueOfSelectedItem as? String { submit(name) }
    }
}

/// Стек карточек должен расти сверху вниз, а не снизу вверх, как по умолчанию у NSClipView.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
