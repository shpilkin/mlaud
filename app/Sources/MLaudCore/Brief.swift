import Foundation

/// Пункт повестки брифа; план минут необязателен и используется в time-карточках (FR-12.7).
public struct BriefAgendaEntry: Equatable, Sendable {
    public var text: String
    public var planMin: Int?
    public init(text: String, planMin: Int? = nil) {
        self.text = text
        self.planMin = planMin
    }
}

/// Поле вне известных ключей/разделов — сохраняется и возвращается при записи (§3.1).
public struct BriefField: Equatable, Sendable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// `brief.md` — фронт-маттер + разделы; формат намеренно узкий, без YAML-библиотек (FP §4.2).
public struct Brief: Equatable, Sendable {
    public var title: String
    public var template: String
    public var mode: String             // vks | offline
    public var expectedMin: Int
    public var counterpart: String
    public var goal: String
    public var agenda: [BriefAgendaEntry]
    public var prompter: Bool
    public var model: String            // "default" или имя подключения
    public var sections: [String: String]
    public var extra: [BriefField]
    public var extraSections: [BriefField]

    public static let sectionNames = ["Задача встречи", "Собеседник", "Скрипт / методология", "Учитывать / избегать"]
    public static let addendumSection = "Дополнение к промту"

    public init(title: String = "", template: String = "custom", mode: String = "vks", expectedMin: Int = 60,
                counterpart: String = "", goal: String = "", agenda: [BriefAgendaEntry] = [],
                prompter: Bool = false, model: String = "default", sections: [String: String] = [:],
                extra: [BriefField] = [], extraSections: [BriefField] = []) {
        self.title = title
        self.template = template
        self.mode = mode
        self.expectedMin = expectedMin
        self.counterpart = counterpart
        self.goal = goal
        self.agenda = agenda
        self.prompter = prompter
        self.model = model
        self.sections = sections
        self.extra = extra
        self.extraSections = extraSections
    }
}

public enum BriefParser {
    public enum Failure: Error, Equatable {
        case noFrontMatter
        case badValue(key: String, line: Int)
        case badMode(String)
    }

    private static let scalarKeys: Set<String> = [
        "title", "template", "mode", "expected_min", "counterpart", "goal", "prompter", "model",
    ]

    /// Разбор §3.1. Ошибки — с номером строки (1-based, по всему файлу).
    public static func parse(_ text: String) throws -> Brief {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }   // хвостовой перевод строки
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            throw Failure.noFrontMatter
        }
        var brief = Brief()
        var extras: [BriefField] = []
        var idx = 1
        var frontMatterEnd: Int? = nil
        while idx < lines.count {
            let raw = lines[idx]
            if raw.trimmingCharacters(in: .whitespaces) == "---" { frontMatterEnd = idx; break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { idx += 1; continue }
            // Пункт повестки: только с отступом, "  - Текст (N)"; без отступа список кончился (§3.1).
            if line == "agenda:" {                                      // маркер списка; сами пункты ниже
                idx += 1
                continue
            }
            if line.hasPrefix("- "), let first = raw.first, first == " " || first == "\t" {
                var item = String(line.dropFirst(2))
                var plan: Int? = nil
                if item.hasSuffix(")") {
                    let inner = String(item.dropLast())
                    if let open = inner.lastIndex(of: "("),
                       let n = Int(inner[inner.index(after: open)...].trimmingCharacters(in: .whitespaces)), n > 0 {
                        plan = n
                        item = String(inner[..<open]).trimmingCharacters(in: .whitespaces)
                    }
                }
                brief.agenda.append(BriefAgendaEntry(text: item.trimmingCharacters(in: .whitespaces), planMin: plan))
                idx += 1
                continue
            }
            // Скаляр: key: value; хвост " # …" — комментарий.
            if let colon = line.firstIndex(of: ":"), scalarKeys.contains(String(line[..<colon])) {
                let key = String(line[..<colon])
                var value = String(line[line.index(after: colon)...])
                if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
                value = value.trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": brief.title = value
                case "template": brief.template = value.isEmpty ? "custom" : value
                case "mode":
                    guard value == "vks" || value == "offline" else { throw Failure.badMode(value) }
                    brief.mode = value
                case "expected_min":
                    guard let n = Int(value), n > 0 else { throw Failure.badValue(key: key, line: idx + 1) }
                    brief.expectedMin = n
                case "counterpart": brief.counterpart = value
                case "goal": brief.goal = value
                case "prompter":
                    guard value == "on" || value == "off" else { throw Failure.badValue(key: key, line: idx + 1) }
                    brief.prompter = value == "on"
                case "model": brief.model = value.isEmpty ? "default" : value
                default: extras.append(BriefField(key: key, value: value))
                }
            } else if let colon = line.firstIndex(of: ":") {
                // Неизвестный ключ — сохранить в порядке исходника.
                extras.append(BriefField(key: String(line[..<colon]),
                                         value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
            idx += 1
        }
        guard frontMatterEnd != nil else { throw Failure.noFrontMatter }
        brief.extra = extras

        // Тело: разделы по "## ".
        var body = lines[(frontMatterEnd! + 1)...].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var currentTitle: String? = nil
        var currentLines: [String] = []
        var sections: [String: String] = [:]
        var extraSections: [BriefField] = []
        func flush() {
            guard let title = currentTitle else { return }
            let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if Brief.sectionNames.contains(title) || title == Brief.addendumSection {
                sections[title] = text
            } else {
                extraSections.append(BriefField(key: title, value: text))
            }
            currentLines = []
        }
        for line in body {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentTitle != nil {
                currentLines.append(line)
            }
        }
        flush()
        brief.sections = sections
        brief.extraSections = extraSections
        return brief
    }

    /// Каноническая запись §3.1: ключи в порядке нормы, agenda всегда, extra после известных;
    /// байт в байт совпадает с `brief.render` в Python (общие фикстуры).
    public static func encode(_ brief: Brief) -> String {
        func scalar(_ key: String, _ value: String) -> String {
            value.isEmpty ? "\(key):\n" : "\(key): \(value)\n"
        }
        var s = "---\n"
        s += scalar("title", brief.title)
        s += scalar("template", brief.template)
        s += scalar("mode", brief.mode)
        s += scalar("expected_min", String(brief.expectedMin))
        s += scalar("counterpart", brief.counterpart)
        s += scalar("goal", brief.goal)
        s += "agenda:\n"
        for entry in brief.agenda {
            s += entry.planMin.map { "  - \(entry.text) (\($0))\n" } ?? "  - \(entry.text)\n"
        }
        s += scalar("prompter", brief.prompter ? "on" : "off")
        s += scalar("model", brief.model)
        for field in brief.extra {
            s += scalar(field.key, field.value)
        }
        s += "---\n"
        var parts: [String] = []
        for name in Brief.sectionNames + [Brief.addendumSection] {
            if let text = brief.sections[name] {
                parts.append(text.isEmpty ? "## \(name)" : "## \(name)\n\(text)")
            }
        }
        for field in brief.extraSections {
            parts.append(field.value.isEmpty ? "## \(field.key)" : "## \(field.key)\n\(field.value)")
        }
        guard !parts.isEmpty else { return s }
        return s + "\n" + parts.joined(separator: "\n\n") + "\n"
    }

    /// Имя канала собеседника: до первой запятой; пусто → «Собеседник» (= ChannelsSidecar.themLabel).
    public static func themLabel(_ brief: Brief) -> String {
        ChannelsSidecar.themLabel(counterpart: brief.counterpart)
    }
}
