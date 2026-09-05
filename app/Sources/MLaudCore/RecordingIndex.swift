import Foundation

/// Обработанная запись в архиве `ASROutput/AllOutputs/<период>/`: транскрипт и то, что о нём
/// известно из сайдкаров. Сам транскрипт не читается — только имена файлов и метаданные.
public struct Recording: Identifiable, Equatable, Sendable {
    /// `<период>/<base>` — уникально в пределах архива.
    public let id: String
    public let base: String
    /// Имя каталога периода, обычно `YYYY-MM`.
    public let period: String
    public let txt: URL
    public let srt: URL?
    /// Аудио из `.meta.json` (относительно `asr_root`), если сайдкар есть.
    public let audio: URL?
    public let date: Date
    /// Дата — начало записи из `.meta.json` или из имени файла `YYYY-MM-DD_HH-MM-SS_…`
    /// (так называет записи iPhone). Иначе — самая ранняя из дат создания и изменения
    /// транскрипта: сайдкары есть только у записей с сентября 2026, старые не должны
    /// пропадать, а переразметка голосов переписывает транскрипт на месте — mtime тогда
    /// врёт, дата создания остаётся.
    public let dateIsExact: Bool
    public let durationSec: Double?
    /// Имена говорящих из сайдкара разметки (или «Спикер N», если имени нет).
    public let speakers: [String]
    /// Есть кластеры без имени — запись ждёт разметки в «Голосах».
    public let needsLabeling: Bool
    /// Рядом лежит `<base>.prompter.md` — звонок с суфлёром, есть итоги.
    public let hasPrompter: Bool

    public init(id: String, base: String, period: String, txt: URL, srt: URL?, audio: URL?,
                date: Date, dateIsExact: Bool, durationSec: Double?, speakers: [String],
                needsLabeling: Bool, hasPrompter: Bool) {
        self.id = id
        self.base = base
        self.period = period
        self.txt = txt
        self.srt = srt
        self.audio = audio
        self.date = date
        self.dateIsExact = dateIsExact
        self.durationSec = durationSec
        self.speakers = speakers
        self.needsLabeling = needsLabeling
        self.hasPrompter = hasPrompter
    }

    /// Приблизительная дата попала в месяц каталога периода. Если нет (файл скопирован или
    /// переписан целиком позже), показывать её как дату и сортировать по ней нельзя.
    public var dateFitsPeriod: Bool {
        guard let month = RecordingIndex.month(ofPeriod: period) else { return true }
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return c.year == month.year && c.month == month.month
    }

    /// Ключ сортировки: точная или правдоподобная дата, иначе — в самый низ.
    var sortDate: Date { dateIsExact || dateFitsPeriod ? date : .distantPast }
}

/// Индекс архива транскриптов: скан каталогов периодов, `.meta.json` конвейера
/// (пишет worker, `artifact.py`) и сайдкары разметки голосов из `service/speakers/`.
public struct RecordingIndex {
    struct Meta: Decodable {
        let startedAt: String?
        let durationSec: Double?
        let audioPath: String?
        let asrRoot: String?

        enum CodingKeys: String, CodingKey {
            case startedAt = "started_at"
            case durationSec = "duration_sec"
            case audioPath = "audio_path"
            case asrRoot = "asr_root"
        }
    }

    public let root: URL
    public let speakersRoot: URL?

    public init(root: URL, speakersRoot: URL? = nil) {
        self.root = root
        self.speakersRoot = speakersRoot
    }

    /// Все записи, новые сверху. Каталог периода — любой подкаталог архива; файл — любой
    /// `.txt` в нём. Битый или отсутствующий сайдкар — не повод прятать запись.
    public func scan() -> [Recording] {
        let fm = FileManager.default
        guard let periods = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let speakers = speakersByKey()
        var out: [Recording] = []
        for periodURL in periods {
            guard (try? periodURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: periodURL, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            let period = periodURL.lastPathComponent
            let names = Set(files.map(\.lastPathComponent))
            for txt in files where txt.pathExtension == "txt" {
                let base = txt.deletingPathExtension().lastPathComponent
                let meta = Self.readMeta(periodURL.appendingPathComponent(base + ".meta.json"))
                let started = meta?.startedAt.flatMap(Self.parseDate) ?? Self.dateFromName(base)
                let stamps = try? txt.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let fallback = [stamps?.creationDate, stamps?.contentModificationDate].compactMap { $0 }.min()
                let info = speakers["\(period)/\(base)"]
                out.append(Recording(
                    id: "\(period)/\(base)",
                    base: base,
                    period: period,
                    txt: txt,
                    srt: names.contains(base + ".srt") ? periodURL.appendingPathComponent(base + ".srt") : nil,
                    audio: Self.audioURL(meta),
                    date: started ?? fallback ?? .distantPast,
                    dateIsExact: started != nil,
                    durationSec: meta?.durationSec,
                    speakers: info?.names ?? [],
                    needsLabeling: info?.pending ?? false,
                    hasPrompter: names.contains(base + ".prompter.md")))
            }
        }
        return out.sorted { $0.sortDate == $1.sortDate ? $0.base > $1.base : $0.sortDate > $1.sortDate }
    }

    /// Поиск по подстрокам: каждое слово запроса должно встретиться в имени записи, в именах
    /// говорящих или в дате (`03.09`, `03.09.2026`, `2026-09-03`).
    public static func matches(_ r: Recording, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = searchText(r).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func searchText(_ r: Recording) -> String {
        var parts = [r.base, r.speakers.joined(separator: " ")]
        if r.dateIsExact || r.dateFitsPeriod {
            parts.append(searchDay.string(from: r.date))
            parts.append(searchISO.string(from: r.date))
        }
        return parts.joined(separator: " ")
    }

    private static let searchDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private static let searchISO: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let periodMonth = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})"#)

    /// `2026-09` (или `2026-06-21` — старый каталог по дню) → год и месяц; иное имя — nil.
    public static func month(ofPeriod period: String) -> (year: Int, month: Int)? {
        let range = NSRange(period.startIndex..., in: period)
        guard let m = periodMonth.firstMatch(in: period, range: range),
              let y = Range(m.range(at: 1), in: period).flatMap({ Int(period[$0]) }),
              let mo = Range(m.range(at: 2), in: period).flatMap({ Int(period[$0]) }),
              (1...12).contains(mo) else { return nil }
        return (y, mo)
    }

    /// Группы по периодам, новые сверху — по имени каталога (`2026-09` > `2026-08`), а не по
    /// самой свежей записи в нём: у записи без сайдкара дата — mtime, и один переразмеченный
    /// файл иначе поднимал бы весь август над сентябрём.
    public static func grouped(_ recordings: [Recording]) -> [(period: String, items: [Recording])] {
        var groups: [String: [Recording]] = [:]
        for r in recordings { groups[r.period, default: []].append(r) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    // MARK: - Сайдкары

    private static func readMeta(_ url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ text: String) -> Date? {
        iso.date(from: text)
    }

    private static let nameStamp = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})"#)

    /// `2026-09-03_16-18-10_Запись 14` → 3 сентября 2026, 16:18:10 по местному времени.
    public static func dateFromName(_ base: String) -> Date? {
        let range = NSRange(base.startIndex..., in: base)
        guard let m = nameStamp.firstMatch(in: base, range: range) else { return nil }
        func part(_ i: Int) -> Int? { Range(m.range(at: i), in: base).flatMap { Int(base[$0]) } }
        var c = DateComponents()
        c.year = part(1); c.month = part(2); c.day = part(3)
        c.hour = part(4); c.minute = part(5); c.second = part(6)
        guard let month = c.month, (1...12).contains(month), let day = c.day, (1...31).contains(day),
              let hour = c.hour, hour < 24, let minute = c.minute, minute < 60,
              let second = c.second, second < 60 else { return nil }
        return Calendar.current.date(from: c)
    }

    private static func audioURL(_ meta: Meta?) -> URL? {
        guard let meta, let path = meta.audioPath else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let rootPath = meta.asrRoot else { return nil }
        return URL(fileURLWithPath: rootPath).appendingPathComponent(path)
    }

    private struct SpeakerInfo {
        let names: [String]
        let pending: Bool
    }

    private func speakersByKey() -> [String: SpeakerInfo] {
        guard let speakersRoot else { return [:] }
        var out: [String: SpeakerInfo] = [:]
        for rec in SpeakerSidecarStore(root: speakersRoot).recent() {
            let sidecar = rec.sidecar
            let names = sidecar.clusters
                .filter { !$0.isCollapsed && ($0.assigned != nil || $0.isLong(minSpeech: sidecar.minSpeech)) }
                .map(\.currentName)
            out["\(sidecar.period)/\(sidecar.base)"] = SpeakerInfo(
                names: names, pending: sidecar.pendingCount > 0)
        }
        return out
    }
}
