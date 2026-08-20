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
