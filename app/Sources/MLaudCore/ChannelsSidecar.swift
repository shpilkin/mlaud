import Foundation

/// `<inbox>/<call_id>.channels.json` — метки каналов стерео-записи звонка (feature-prompter.md §4.3, ADR-026).
public struct ChannelsSidecar: Equatable, Sendable {
    public static let version = 1
    public static let suffix = ".channels.json"
    /// Тот же формат, что `CALL_ID_FORMAT = "%Y-%m-%d_%H-%M-%S"` у worker'а.
    public static let callIDFormat = "yyyy-MM-dd_HH-mm-ss"

    public enum DecodeError: Error, Equatable {
        case notJSON
        case version(Int?)
        case callID
        case channels(String)
    }

    public let callID: String
    public let channels: [String: String]   // "0" → «Я», "1" → собеседник
    public let brief: String?

    public init(callID: String, meLabel: String = "Я", themLabel: String, brief: String? = nil) {
        self.callID = callID
        self.channels = [CallChannel.me.key: meLabel, CallChannel.them.key: themLabel]
        self.brief = brief
    }

    init(callID: String, channels: [String: String], brief: String?) {
        self.callID = callID
        self.channels = channels
        self.brief = brief
    }

    public func label(_ ch: CallChannel) -> String {
        channels[ch.key] ?? ch.defaultLabel
    }

    public static func fileName(callID: String) -> String {
        callID + suffix
    }

    /// feature-prompter.md:321-322: до первой запятой; пусто/nil → «Собеседник».
    public static func themLabel(counterpart: String?) -> String {
        guard let counterpart else { return CallChannel.them.defaultLabel }
        let head = counterpart.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CallChannel.them.defaultLabel : trimmed
    }

    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = callIDFormat
        return f
    }

    /// "yyyy-MM-dd_HH-mm-ss" в календаре/зоне `calendar` (по умолчанию .current).
    public static func callID(startedAt: Date, calendar: Calendar = .current) -> String {
        formatter(calendar).string(from: startedAt)
    }

    public static func startedAt(callID: String, calendar: Calendar = .current) -> Date? {
        formatter(calendar).date(from: callID)
    }

    /// Одна строка + "\n", порядок ключей фиксирован, brief опущен, если nil:
    /// {"version":1,"call_id":"2026-09-04_15-30-05","channels":{"0":"Я","1":"Иван Петров"},"brief":"…"}
    public func encoded() -> Data {
        var s = "{\"version\":\(Self.version),\"call_id\":\(JSONText.quoted(callID)),\"channels\":{"
        s += channels.keys.sorted()
            .map { "\(JSONText.quoted($0)):\(JSONText.quoted(channels[$0] ?? ""))" }
            .joined(separator: ",")
        s += "}"
        if let brief {
            s += ",\"brief\":\(JSONText.quoted(brief))"
        }
        s += "}\n"
        return Data(s.utf8)
    }

    public static func decode(_ data: Data) throws -> ChannelsSidecar {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        let version = obj["version"] as? Int
        guard version == Self.version else { throw DecodeError.version(version) }
        guard let callID = obj["call_id"] as? String else { throw DecodeError.callID }
        guard let raw = obj["channels"] as? [String: Any] else { throw DecodeError.channels("нет channels") }
        var channels: [String: String] = [:]
        for (key, value) in raw {
            guard let label = value as? String else { throw DecodeError.channels("канал \(key) — не строка") }
            channels[key] = label
        }
        for ch in CallChannel.allCases where channels[ch.key] == nil {
            throw DecodeError.channels("нет канала \(ch.key)")
        }
        return ChannelsSidecar(callID: callID, channels: channels, brief: obj["brief"] as? String)
    }
}
