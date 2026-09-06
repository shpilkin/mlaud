import Foundation

/// Событие резидентного процесса диктовки (`python -m mlaud_worker.dictate`).
public enum DictationEvent: Equatable {
    case ready
    case commit(String)
    case preview(String)
    case error(String)
    /// Как закрылась фраза: паузой или упором в предел окна, и во сколько разборов
    /// это обошлось. Не влияет на текст — нужно, чтобы видеть, что происходит.
    case stat(reason: String, windowSec: Double, decodes: Int)

    /// Разбор одной строки stdout. nil — строка не из протокола (предупреждения
    /// библиотек тоже летят в stdout, ронять на них сессию нельзя).
    public static func parse(line: String) -> DictationEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["t"] as? String
        else { return nil }
        switch kind {
        case "ready":   return .ready
        case "commit":  return .commit(obj["text"] as? String ?? "")
        case "preview": return .preview(obj["text"] as? String ?? "")
        case "error":   return .error(obj["message"] as? String ?? "")
        case "stat":
            return .stat(reason: obj["reason"] as? String ?? "?",
                         windowSec: obj["window_sec"] as? Double ?? 0,
                         decodes: obj["decodes"] as? Int ?? 0)
        default:        return nil
        }
    }
}

/// Команда резидентному процессу.
public enum DictationCommand {
    case audio(Data)   // int16 LE, 16 кГц, mono
    case flush         // конец фразы: докоммитить всё
    case reset         // выбросить накопленное, ничего не печатать
    case quit

    public func line() -> String {
        switch self {
        case .audio(let pcm):
            return #"{"t":"audio","pcm":"\#(pcm.base64EncodedString())"}"#
        case .flush: return #"{"t":"flush"}"#
        case .reset: return #"{"t":"reset"}"#
        case .quit:  return #"{"t":"quit"}"#
        }
    }

    public func data() -> Data {
        Data((line() + "\n").utf8)
    }
}

/// Собирает целые строки из кусков, в которых их приносит пайп.
/// Чтение по 4 КБ режет JSON посередине — без сборки половина событий теряется.
public struct LineBuffer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
        }
        return lines
    }
}

/// Склейка кусков текста в поток печати: решает, где нужен пробел.
/// Модель отдаёт слова без ведущих пробелов, а печатаем мы подряд —
/// без этого получилось бы «Так,погнали.Давайте».
public struct TextJoiner {
    private var started = false

    public init() {}

    /// Что именно набрать для очередного куска (может начинаться с пробела).
    public mutating func next(_ chunk: String) -> String {
        let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.isEmpty { return "" }
        defer { started = true }
        if !started { return piece }
        if let first = piece.first, ",.!?;:)»".contains(first) { return piece }
        return " " + piece
    }

    /// Новая диктовка — следующий кусок снова без ведущего пробела.
    public mutating func reset() { started = false }
}

/// Ручное кодирование JSON: JSONSerialization не гарантирует порядок ключей и печатает
/// 0.30000000000000004 — тесты форматов сравнивают байты.
public enum JSONText {
    /// Строка в кавычках: \" \\ \n \r \t, прочие < 0x20 — \u00XX. Кириллица как есть.
    public static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Число протокола/jsonl: не больше двух знаков после запятой, хвостовые нули срезаны:
    /// 183.2 → "183.2", 190.0 → "190", 0.049 → "0.05", -0.0 → "0".
    public static func number(_ x: Double) -> String {
        guard x.isFinite else { return "0" }
        var s = String(format: "%.2f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

/// Команда каналу живого звонка (feature-prompter.md §5.1). Без `ch` — DictationCommand.
public enum ChannelCommand: Equatable {
    case open(ch: String, label: String)
    case audio(ch: String, pcm: Data)   // int16 LE, 16 кГц, mono
    case flush(ch: String)
    case reset(ch: String)
    case close(ch: String)

    public func line() -> String {
        switch self {
        case .open(let ch, let label):
            return #"{"t":"open","ch":\#(JSONText.quoted(ch)),"label":\#(JSONText.quoted(label))}"#
        case .audio(let ch, let pcm):
            return #"{"t":"audio","ch":\#(JSONText.quoted(ch)),"pcm":"\#(pcm.base64EncodedString())"}"#
        case .flush(let ch):
            return #"{"t":"flush","ch":\#(JSONText.quoted(ch))}"#
        case .reset(let ch):
            return #"{"t":"reset","ch":\#(JSONText.quoted(ch))}"#
        case .close(let ch):
            return #"{"t":"close","ch":\#(JSONText.quoted(ch))}"#
        }
    }

    public func data() -> Data {
        Data((line() + "\n").utf8)
    }
}

/// Закрытая фраза канала. windowSec/decodes — поля бывшего stat.
public struct ChannelPhrase: Equatable, Sendable {
    public let phrase: Int
    public let t0: Double        // секунды принятого звука канала от open
    public let t1: Double
    public let text: String      // вся фраза целиком (финальный разбор окна)
    public let reason: String    // "silence" | "overflow" | "flush"
    public let windowSec: Double
    public let decodes: Int

    public init(phrase: Int, t0: Double, t1: Double, text: String, reason: String, windowSec: Double, decodes: Int) {
        self.phrase = phrase
        self.t0 = t0
        self.t1 = t1
        self.text = text
        self.reason = reason
        self.windowSec = windowSec
        self.decodes = decodes
    }
}

public enum ChannelEvent: Equatable, Sendable {
    case commit(phrase: Int, text: String)
    case preview(phrase: Int, text: String)
    case phrase(ChannelPhrase)
    case error(String)
}

/// Строка stdout распознавателя: с полем "ch" — событие канала, без — событие диктовки
/// (включая ready). Неизвестный t → nil, как в DictationEvent.parse.
public enum RecognizerEvent: Equatable {
    case dictation(DictationEvent)
    case channel(ch: String, ChannelEvent)

    public static func parse(line: String) -> RecognizerEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let ch = obj["ch"] as? String else {
            return DictationEvent.parse(line: line).map { .dictation($0) }
        }
        guard let kind = obj["t"] as? String else { return nil }
        let phrase = obj["phrase"] as? Int ?? 0
        let text = obj["text"] as? String ?? ""
        switch kind {
        case "commit":  return .channel(ch: ch, .commit(phrase: phrase, text: text))
        case "preview": return .channel(ch: ch, .preview(phrase: phrase, text: text))
        case "phrase":
            return .channel(ch: ch, .phrase(ChannelPhrase(
                phrase: phrase,
                t0: obj["t0"] as? Double ?? 0,
                t1: obj["t1"] as? Double ?? 0,
                text: text,
                reason: obj["reason"] as? String ?? "?",
                windowSec: obj["window_sec"] as? Double ?? 0,
                decodes: obj["decodes"] as? Int ?? 0)))
        case "error":   return .channel(ch: ch, .error(obj["message"] as? String ?? ""))
        default:        return nil
        }
    }
}
