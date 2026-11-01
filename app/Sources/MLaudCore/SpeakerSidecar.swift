import Foundation

/// Сайдкар записи, который worker пишет для разметки голосов
/// (`~/ASR/service/speakers/<YYYY-MM>/<base>/speakers.json`, схема —
/// docs/feature-speaker-id.md §6.2). Приложение его только читает: все изменения
/// идут через `python -m mlaud_worker.voices`, чтобы у файла был один писатель.
public struct SpeakerMatch: Decodable, Equatable, Sendable {
    public let name: String
    public let score: Double
    public let sure: Bool

    public init(name: String, score: Double, sure: Bool) {
        self.name = name
        self.score = score
        self.sure = sure
    }
}

public struct SpeakerCluster: Decodable, Equatable, Sendable {
    public let label: String
    public let display: String
    public let speechSec: Double
    public let firstAt: Double
    public let nTurns: Int
    public let quote: String
    public let clips: [String]
    /// Секунда записи, с которой начинается каждый клип (та же длина, что `clips`;
    /// у старых сайдкаров пусто).
    public let clipStarts: [Double]
    /// Вектор в приложении не нужен, а весит больше всего остального: храним только факт.
    public let hasEmbedding: Bool
    public let match: SpeakerMatch?
    public let written: String
    public let assigned: String?
    public let dismissed: Bool
    /// В кластере слышно нескольких: в базу нельзя, имени не будет.
    public let mixed: Bool
    /// Убран из списка корзиной: не показывается, пока не попросят.
    public let hidden: Bool
    public let rejected: [String]

    enum CodingKeys: String, CodingKey {
        case label, display, quote, clips, embedding, match, written, assigned, dismissed, mixed,
             hidden, rejected
        case speechSec = "speech_sec"
        case firstAt = "first_at"
        case nTurns = "n_turns"
        case clipStarts = "clip_starts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        display = try c.decode(String.self, forKey: .display)
        speechSec = try c.decodeIfPresent(Double.self, forKey: .speechSec) ?? 0
        firstAt = try c.decodeIfPresent(Double.self, forKey: .firstAt) ?? 0
        nTurns = try c.decodeIfPresent(Int.self, forKey: .nTurns) ?? 0
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        clips = try c.decodeIfPresent([String].self, forKey: .clips) ?? []
        clipStarts = try c.decodeIfPresent([Double].self, forKey: .clipStarts) ?? []
        hasEmbedding = c.contains(.embedding) && !((try? c.decodeNil(forKey: .embedding)) ?? true)
        match = try c.decodeIfPresent(SpeakerMatch.self, forKey: .match)
        written = try c.decodeIfPresent(String.self, forKey: .written) ?? display
        assigned = try c.decodeIfPresent(String.self, forKey: .assigned)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        mixed = try c.decodeIfPresent(Bool.self, forKey: .mixed) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        rejected = try c.decodeIfPresent([String].self, forKey: .rejected) ?? []
    }

    public init(label: String, display: String, speechSec: Double, firstAt: Double = 0,
                nTurns: Int = 0, quote: String = "", clips: [String] = [],
                clipStarts: [Double] = [], hasEmbedding: Bool = true,
                match: SpeakerMatch? = nil, written: String? = nil,
                assigned: String? = nil, dismissed: Bool = false, mixed: Bool = false,
                hidden: Bool = false, rejected: [String] = []) {
        self.label = label
        self.display = display
        self.speechSec = speechSec
        self.firstAt = firstAt
        self.nTurns = nTurns
        self.quote = quote
        self.clips = clips
        self.clipStarts = clipStarts
        self.hasEmbedding = hasEmbedding
        self.match = match
        self.written = written ?? display
        self.assigned = assigned
        self.dismissed = dismissed
        self.mixed = mixed
        self.hidden = hidden
        self.rejected = rejected
    }

    /// Узнавание, от которого не отказались кнопкой «Нет».
    public var effectiveMatch: SpeakerMatch? {
        guard let m = match, !rejected.contains(m.name) else { return nil }
        return m
    }

    /// Что должно стоять в транскрипте сейчас — то же правило, что в speakers.py.
    public static let mixedSuffix = " (смесь голосов)"

    public var currentName: String {
        if let assigned, !assigned.isEmpty { return assigned }
        if mixed { return display + Self.mixedSuffix }
        if dismissed { return display }
        if let m = effectiveMatch { return m.sure ? m.name : "\(m.name)(?)" }
        return display
    }

    public func isLong(minSpeech: Double) -> Bool { speechSec >= minSpeech }

    /// Длинный кластер без имени: не узнан или узнан неуверенно и не подтверждён.
    public func needsAttention(minSpeech: Double) -> Bool {
        guard isLong(minSpeech: minSpeech), hasEmbedding else { return false }
        if let assigned, !assigned.isEmpty { return false }
        if dismissed || mixed || hidden { return false }
        return !(effectiveMatch?.sure ?? false)
    }

    /// Свёрнутая карточка: человек убрал кластер из разметки.
    public var isCollapsed: Bool { assigned == nil && (dismissed || mixed || hidden) }
}

public struct SpeakerSidecar: Decodable, Sendable {
    public let version: Int
    public let source: String
    public let base: String
    public let period: String
    public let processedAt: Date?
    public let txt: String
    public let srt: String
    public let durationSec: Double
    public let threshold: Double
    public let minSpeech: Double
    public let clusters: [SpeakerCluster]
    public let clipsError: String?
    /// Надгробие: `forgotten` («Убрать из списка») или `swept` (ретенция) — клипов и
    /// векторов нет, имена остались. В «Голосах» не показывается, в «Записях» — говорящие есть.
    public let removed: String?

    enum CodingKeys: String, CodingKey {
        case version, source, base, period, txt, srt, threshold, clusters, removed
        case processedAt = "processed_at"
        case durationSec = "duration_sec"
        case minSpeech = "min_speech"
        case clipsError = "clips_error"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        source = try c.decode(String.self, forKey: .source)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? source
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? ""
        processedAt = (try c.decodeIfPresent(String.self, forKey: .processedAt))
            .flatMap { Self.iso.date(from: $0) }
        txt = try c.decodeIfPresent(String.self, forKey: .txt) ?? ""
        srt = try c.decodeIfPresent(String.self, forKey: .srt) ?? ""
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.75
        minSpeech = try c.decodeIfPresent(Double.self, forKey: .minSpeech) ?? 30
        clusters = try c.decodeIfPresent([SpeakerCluster].self, forKey: .clusters) ?? []
        clipsError = try c.decodeIfPresent(String.self, forKey: .clipsError)
        removed = try c.decodeIfPresent(String.self, forKey: .removed)
    }

    public var isRemoved: Bool { removed != nil }

    /// Сколько кластеров ждут разметки; у надгробия — ноль.
    public var pendingCount: Int {
        isRemoved ? 0 : clusters.filter { $0.needsAttention(minSpeech: minSpeech) }.count
    }

    /// Есть ли вообще кому ставить имя: кластеры с речью не короче порога и с вектором.
    public var hasLabelableClusters: Bool {
        clusters.contains { $0.isLong(minSpeech: minSpeech) && $0.hasEmbedding }
    }

    public static func load(_ url: URL) throws -> SpeakerSidecar {
        try JSONDecoder().decode(SpeakerSidecar.self, from: Data(contentsOf: url))
    }
}

/// Одна запись в окне «Голоса»: сайдкар и где он лежит (клипы — рядом).
public struct SpeakerRecording: Sendable {
    public let url: URL
    public let sidecar: SpeakerSidecar
    /// Время обработки; если в файле его нет — mtime файла.
    public let date: Date

    public var directory: URL { url.deletingLastPathComponent() }

    public func clipURLs(for cluster: SpeakerCluster) -> [URL] {
        cluster.clips.map { directory.appendingPathComponent($0) }
    }
}

/// Каталог сайдкаров `~/ASR/service/speakers/`.
public struct SpeakerSidecarStore {
    public static let fileName = "speakers.json"
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Все записи, новые сверху. Битые файлы пропускаются: одна испорченная запись
    /// не должна прятать остальные. Надгробия — только по просьбе (индекс «Записей»).
    public func recent(includeRemoved: Bool = false) -> [SpeakerRecording] {
        let fm = FileManager.default
        guard let periods = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [SpeakerRecording] = []
        for period in periods {
            guard let recs = try? fm.contentsOfDirectory(at: period, includingPropertiesForKeys: nil)
            else { continue }
            for rec in recs {
                let url = rec.appendingPathComponent(Self.fileName)
                guard let sidecar = try? SpeakerSidecar.load(url),
                      includeRemoved || !sidecar.isRemoved else { continue }
                let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    ?? .distantPast
                out.append(SpeakerRecording(url: url, sidecar: sidecar,
                                            date: sidecar.processedAt ?? mtime))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    public func pendingCount() -> Int {
        recent().reduce(0) { $0 + $1.sidecar.pendingCount }
    }
}
