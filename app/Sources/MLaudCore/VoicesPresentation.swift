import Foundation

/// Подписи раздела «Голоса», которые проверяются без UI: состояние записи, строки карточки
/// кластера, плашка узнавания, строки списка людей (feature-speaker-id.md §4.2, §4.4).
public enum VoicesPresentation {
    /// Канал записи: значение для worker'а (`--channel`) и подпись в списке.
    public struct Channel: Identifiable, Equatable, Sendable {
        public let value: String
        public let title: String
        public var id: String { value }
    }

    public static let channels: [Channel] = [
        Channel(value: "phone", title: "телефон"),
        Channel(value: "vks", title: "ВКС"),
        Channel(value: "other", title: "другое"),
        Channel(value: "reference", title: "эталон"),
    ]
    public static let defaultChannel = "other"

    public static func channelTitle(_ value: String) -> String {
        channels.first { $0.value == value }?.title ?? value
    }

    /// Состояние записи: сколько ждёт, всё названо или размечать нечего.
    public static func recordingStatus(_ s: SpeakerSidecar) -> String {
        let pending = s.pendingCount
        if pending > 0 { return "\(pending) к разметке" }
        if s.hasLabelableClusters { return "все названы" }
        return "нечего размечать: речи меньше \(Int(s.minSpeech)) с"
    }

    public static func mmss(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// Первая строка карточки: метка, объём речи, откуда слышен.
    public static func clusterTitle(_ c: SpeakerCluster) -> String {
        "\(c.display) · \(mmss(c.speechSec)) речи · с \(mmss(c.firstAt))"
    }

    /// Вторая строка: цитата; у короткого кластера — почему имя пойдёт только в транскрипт (FR-8.9).
    public static func clusterSubtitle(_ c: SpeakerCluster, minSpeech: Double) -> String {
        let quoted = c.quote.isEmpty ? "" : "«\(c.quote)»"
        if c.isCollapsed || (c.isLong(minSpeech: minSpeech) && c.hasEmbedding) { return quoted }
        return "речи меньше \(mmss(minSpeech)): имя пойдёт только в транскрипт, отпечаток в базу не снять"
            + (quoted.isEmpty ? "" : " · \(quoted)")
    }

    /// Подпись кнопки фрагмента: таймкод начала; у старых сайдкаров без `clip_starts` — номер.
    public static func clipTitle(_ c: SpeakerCluster, index: Int) -> String {
        index < c.clipStarts.count ? mmss(c.clipStarts[index]) : "\(index + 1)"
    }

    /// Плашка справа в карточке: что о кластере известно.
    public enum Badge: Equatable {
        case hidden, mixed, unnamed
        case assigned(String)
        case sure(String, Double)
        case unsure(String, Double)

        public var text: String {
            switch self {
            case .hidden: return "убран из списка"
            case .mixed: return "смесь / неразборчиво"
            case .unnamed: return "без имени"
            case .assigned(let name): return "✓ \(name)"
            case .sure(let name, let score): return "✓ \(name) · " + String(format: "%.2f", score)
            case .unsure(let name, let score): return "\(name) (?) · " + String(format: "%.2f", score)
            }
        }
    }

    public static func badge(for c: SpeakerCluster) -> Badge? {
        if c.isCollapsed {
            if c.hidden { return .hidden }
            return c.mixed ? .mixed : .unnamed
        }
        if let assigned = c.assigned, !assigned.isEmpty { return .assigned(assigned) }
        if let m = c.effectiveMatch { return m.sure ? .sure(m.name, m.score) : .unsure(m.name, m.score) }
        return nil
    }

    /// Поле «Кто это?» показывается, пока имя не стоит: у подписанных и уверенно узнанных
    /// его нет (имя меняют карандашом), у свёрнутых — тоже. Короткому кластеру поле нужно:
    /// имя пойдёт в транскрипт (FR-8.9).
    public static func needsNameField(_ c: SpeakerCluster) -> Bool {
        if c.isCollapsed { return false }
        if let assigned = c.assigned, !assigned.isEmpty { return false }
        return !(c.effectiveMatch?.sure ?? false)
    }

    public static func personLine(_ p: VoicePerson) -> String {
        let n = p.samples.count
        return "\(n) \(RussianPlural.form(n, "образец", "образца", "образцов")) · с \(p.created.prefix(10))"
    }

    public static func sampleLine(_ s: VoiceSample) -> String {
        "\(Int(s.speechSec)) с · \(channelTitle(s.channel)) · \(s.sourceFile) · \(s.added.prefix(10))"
    }
}

extension SpeakerRecording: Identifiable {
    public var id: URL { url }
}

extension SpeakerCluster: Identifiable {
    public var id: String { label }
}

extension VoicePerson: Identifiable {
    public var id: String { name }
}

extension VoiceSample: Identifiable {}
