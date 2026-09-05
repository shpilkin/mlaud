import AppKit
import AVFoundation
import MLaudCore
import Observation

/// Состояние раздела «Голоса»: сайдкары записей, база людей, выбранная запись, занятость
/// worker'а. Логика прежнего окна `VoicesWindowController` без представления: экран читает
/// свойства и зовёт методы; сайдкары и базу приложение только читает, любое изменение —
/// через `python -m mlaud_worker.voices`, чтобы у файлов был один писатель (ADR-017).
///
/// Просмотрщика транскрипта у приложения нет, поэтому размечаем не «по абзацам», а по
/// кластерам: worker сохранил вектор, цитату и клипы каждого (сайдкар, §6.2 фичи), и
/// имя ставится на кластер целиком.
@Observable
final class VoicesModel {
    enum Tab: Hashable { case label, people }

    enum ClusterAction {
        case assign(String)   // имя из поля или из списка
        case confirm          // «Да, он» — имя из автоузнавания
        case reject           // «Нет» / «Не он»
        case none             // оставить без имени
        case mixed            // несколько голосов
        case delete           // корзина: убрать из списка
        case restore          // вернуть свёрнутый кластер к разметке
    }

    struct Playing: Equatable {
        let label: String
        let index: Int
    }

    private let store: SpeakerSidecarStore
    private let runner: VoicesRunner
    private let onChange: () -> Void
    /// Как показать ошибку worker'а: в приложении — модальное окно, в дымовой проверке — печать.
    var presentError: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = "Не получилось"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    var tab: Tab = .label
    private(set) var recordings: [SpeakerRecording] = []
    private(set) var listing: VoiceListing?
    private(set) var selectedURL: URL?
    var showHidden = false
    var channel = VoicesPresentation.defaultChannel
    private(set) var busy = false
    /// Последняя строка вывода worker'а («переподписано строк: N», «отправлено: …») или ход
    /// подготовки старой записи.
    private(set) var status = ""
    private(set) var playing: Playing?
    /// Кластер, к которому перешли из «Людей»: карточка подсвечена и прокручена в видимость.
    private(set) var highlighted: String?

    private var prepareQueue: [URL] = []
    private var prepareTotal = 0
    /// Куда перейти после подготовки записи из архива (образец без сайдкара).
    private var pendingReveal: (source: String, label: String)?
    private var player: AVAudioPlayer?
    private let playerDelegate = PlayerDelegate()

    init(store: SpeakerSidecarStore, runner: VoicesRunner, onChange: @escaping () -> Void) {
        self.store = store
        self.runner = runner
        self.onChange = onChange
        playerDelegate.onFinish = { [weak self] in self?.stopPlayback() }
    }

    // MARK: - Чтение

    var selected: SpeakerRecording? {
        recordings.first { $0.url == selectedURL }
    }

    var people: [String] { listing?.names ?? [] }

    var hiddenCount: Int {
        selected?.sidecar.clusters.filter(\.hidden).count ?? 0
    }

    /// Карточки выбранной записи; убранные корзиной — только по флажку.
    var visibleClusters: [SpeakerCluster] {
        (selected?.sidecar.clusters ?? []).filter { !$0.hidden || showHidden }
    }

    /// Заголовок над карточками: имя записи и состояние; дата уже стоит в списке слева.
    var header: String {
        guard let rec = selected else { return "" }
        return "\(rec.sidecar.base) · " + VoicesPresentation.recordingStatus(rec.sidecar)
    }

    /// Перечитать сайдкары с диска и базу людей (через worker).
    func reload() {
        recordings = store.recent()
        if let selectedURL, !recordings.contains(where: { $0.url == selectedURL }) {
            self.selectedURL = nil
        }
        if selectedURL == nil { selectedURL = recordings.first?.url }
        runner.run(["list", "--json"]) { [weak self] result in
            guard let self, result.ok,
                  let listing = try? VoiceListing.parse(Data(result.stdout.utf8)) else { return }
            self.listing = listing
        }
    }

    func select(_ rec: SpeakerRecording) {
        guard rec.url != selectedURL else { return }
        stopPlayback()
        selectedURL = rec.url
    }

    // MARK: - Карточки

    func apply(_ action: ClusterAction, to cluster: SpeakerCluster) {
        guard let rec = selected else { return }
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

    // MARK: - Прослушивание

    func togglePlay(cluster: SpeakerCluster, index: Int) {
        guard let rec = selected else { return }
        let clips = rec.clipURLs(for: cluster)
        guard index >= 0, index < clips.count else { return }
        let target = Playing(label: cluster.label, index: index)
        if playing == target, player?.isPlaying == true {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: clips[index]) else { return }
        p.delegate = playerDelegate
        player = p
        playing = target
        p.play()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    // MARK: - Старые записи и удаление из списка

    /// Записи, обработанные до включения идентификации, сайдкара не имеют. Кнопка гонит
    /// выбранные файлы из архива через worker заново (транскрипт + сайдкар, без доставки).
    func prepareOld() {
        let panel = NSOpenPanel()
        panel.message = "Транскрипт будет сделан заново с именами из базы. В Telegram ничего не уходит."
        panel.prompt = "Разметить"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = Self.archive
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        prepareQueue = panel.urls
        prepareTotal = panel.urls.count
        prepareNext()
    }

    private func prepareNext() {
        guard !prepareQueue.isEmpty else { return }
        let url = prepareQueue.removeFirst()
        let n = prepareTotal - prepareQueue.count
        status = "Обрабатываю «\(url.deletingPathExtension().lastPathComponent)» "
            + "(\(n)/\(prepareTotal)) — минуту-две…"
        run(["prepare", url.path]) { [weak self] ok in
            guard let self else { return }
            if ok, let rec = self.recordings.first(where: { $0.sidecar.source == url.lastPathComponent }) {
                self.selectedURL = rec.url
                if let pending = self.pendingReveal, pending.source == url.lastPathComponent {
                    self.pendingReveal = nil
                    self.highlight(pending.label)
                }
            }
            self.prepareNext()
        }
    }

    /// Убрать запись из разметки: удаляется её каталог с клипами и векторами.
    /// Транскрипт и уже сохранённые голоса не трогаются.
    func forgetSelected() {
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

    func relabel() {
        guard let rec = selected else { return }
        run(["relabel", rec.url.path])
    }

    func resend() {
        guard let rec = selected else { return }
        run(["resend", rec.url.path])
    }

    // MARK: - Люди

    /// Показать кластер записи во вкладке «Разметить». Сайдкара нет (запись обработана до
    /// включения разметки или убрана) — предложить подготовить её из архива.
    @discardableResult
    func reveal(source: String, label: String) -> Bool {
        if let rec = recordings.first(where: { $0.sidecar.source == source }) {
            tab = .label
            if rec.url != selectedURL { select(rec) }
            highlight(label)
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
        tab = .label
        prepareQueue = [audio]
        prepareTotal = 1
        prepareNext()
        return true
    }

    func rename(_ person: VoicePerson) {
        guard let name = askName(title: "Переименовать",
                                 message: "Новое имя для «\(person.name)» — в базе и в размеченных записях.",
                                 initial: person.name), name != person.name else { return }
        run(["rename", person.name, name])
    }

    func remove(_ person: VoicePerson) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить «\(person.name)» и \(person.samples.count) образц.?"
        alert.informativeText = "Голос перестанет узнаваться. Транскрипты не меняются."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(["remove", "--person", person.name])
    }

    func remove(_ sample: VoiceSample, of person: VoicePerson) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить образец «\(person.name)» из \(sample.sourceFile)?"
        alert.informativeText = "Остальные образцы этого человека остаются."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(["remove", "--sample", sample.id])
    }

    // MARK: - Внутреннее

    private static let archive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ASR/Processed/AllRecords")

    private static func findInArchive(_ name: String) -> URL? {
        guard let walker = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name { return url }
        return nil
    }

    /// Подсветить карточку на пару секунд: сюда перешли из вкладки «Люди».
    private func highlight(_ label: String) {
        highlighted = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.highlighted == label { self?.highlighted = nil }
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
                self.status = ""
                self.presentError(result.message)
            } else if ["resend", "relabel", "prepare", "forget"].contains(args.first ?? "") {
                self.status = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
            }
            self.reload()
            self.onChange()
            then?(result.ok)
        }
    }

    // MARK: - Дымовая проверка (main.swift --smoke-voices)

    /// «Оставить без имени» для первого кластера к разметке — тот же путь, что клик в карточке.
    func dismissFirstPending() -> Bool {
        guard let rec = selected,
              let cluster = rec.sidecar.clusters.first(where: {
                  $0.needsAttention(minSpeech: rec.sidecar.minSpeech) })
        else { return false }
        apply(.none, to: cluster)
        return true
    }

    func smokeReport() -> String {
        "recordings=\(recordings.count) cards=\(visibleClusters.count) "
        + "people=\(listing?.people.count ?? -1) pending=\(selected?.sidecar.pendingCount ?? -1) "
        + "busy=\(busy) tab=\(tab) highlighted=\(highlighted ?? "-") header=«\(header)»"
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void = {}

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
