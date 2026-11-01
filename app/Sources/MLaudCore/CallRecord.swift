import Foundation

/// `~/ASR/Prompter/calls/<call_id>/call.json` (§3.2).
public struct CallRecord: Equatable, Sendable {
    public static let version = 1
    public static let fileName = "call.json"

    public enum DecodeError: Error, Equatable {
        case notJSON
        case version(Int?)
        case field(String)
    }

    public struct App: Equatable, Sendable {
        public var name: String
        public var bundleID: String
        public var pid: Int32

        public init(name: String, bundleID: String, pid: Int32) {
            self.name = name
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public var callID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSec: Double?
    public var mode = "vks"
    public var brief: String?
    public var inputDevice: String?
    public var outputDevice: String?
    public var app: App?
    public var model: String
    public var channels: [String: String]
    public var recording: String?
    public var meetingID: String?
    public var briefDir: String?                  // slug папки брифа (этап 4, §3.5)
    public var prompter: PrompterStats?
    public var goalResult: GoalResult?

    /// Числа суфлёра для call.json; пишется при остановке звонка.
    public struct PrompterStats: Equatable, Sendable {
        public var enabled: Bool
        public var connection: String
        public var llmModel: String
        public var turns: Int
        public var promptTokens: Int
        public var cachedTokens: Int
        public var completionTokens: Int
        public var costUSD: Double
        public var firstCardMsMedian: Int?

        public init(enabled: Bool, connection: String, llmModel: String, turns: Int,
                    promptTokens: Int, cachedTokens: Int, completionTokens: Int,
                    costUSD: Double, firstCardMsMedian: Int?) {
            self.enabled = enabled
            self.connection = connection
            self.llmModel = llmModel
            self.turns = turns
            self.promptTokens = promptTokens
            self.cachedTokens = cachedTokens
            self.completionTokens = completionTokens
            self.costUSD = costUSD
            self.firstCardMsMedian = firstCardMsMedian
        }
    }

    public init(callID: String, startedAt: Date, model: String, channels: [String: String]) {
        self.callID = callID
        self.startedAt = startedAt
        self.model = model
        self.channels = channels
    }

    // Как `started_at` в .meta.json (artifact.py:173, isoformat()): смещение всегда ±HH:MM, не "Z".
    private static func dateFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func optional(_ s: String?) -> String {
        s.map(JSONText.quoted) ?? "null"
    }

    /// Ручная сборка через JSONText в порядке §3.2; даты — ISO8601 без долей секунды со смещением `timeZone`
    /// (по умолчанию локальным); отступ 2 пробела, в конце "\n".
    public func encoded(timeZone: TimeZone = .current) -> Data {
        let dates = Self.dateFormatter(timeZone)
        let channelsText = channels.keys.sorted()
            .map { "\(JSONText.quoted($0)): \(JSONText.quoted(channels[$0] ?? ""))" }
            .joined(separator: ", ")
        let appText = app.map {
            "{\"name\": \(JSONText.quoted($0.name)), \"bundle_id\": \(JSONText.quoted($0.bundleID)), \"pid\": \($0.pid)}"
        } ?? "null"
        var s = "{\n"
        s += "  \"version\": \(Self.version),\n"
        s += "  \"call_id\": \(JSONText.quoted(callID)),\n"
        s += "  \"started_at\": \(JSONText.quoted(dates.string(from: startedAt))),\n"
        s += "  \"ended_at\": \(Self.optional(endedAt.map { dates.string(from: $0) })),\n"
        s += "  \"duration_sec\": \(durationSec.map(JSONText.number) ?? "null"),\n"
        s += "  \"mode\": \(JSONText.quoted(mode)),\n"
        s += "  \"brief\": \(Self.optional(brief)),\n"
        s += "  \"devices\": {\n"
        s += "    \"input\": \(Self.optional(inputDevice)),\n"
        s += "    \"output\": \(Self.optional(outputDevice)),\n"
        s += "    \"app\": \(appText)\n"
        s += "  },\n"
        s += "  \"model\": \(JSONText.quoted(model)),\n"
        s += "  \"channels\": {\(channelsText)},\n"
        s += "  \"recording\": \(Self.optional(recording)),\n"
        s += "  \"meeting_id\": \(Self.optional(meetingID))"
        // Ключи этапа 4 — только когда не nil: при всех nil байты те же, что до этапа 4 (§3.5).
        if let briefDir {
            s += ",\n  \"brief_dir\": \(JSONText.quoted(briefDir))"
        }
        if let stats = prompter {
            // Стоимость за звонок — до 4 знаков: JSONText.number (2 знака) превратил бы 0.012 в 0.01 (§3.5).
            var cost = String(format: "%.4f", stats.costUSD)
            while cost.hasSuffix("0") { cost.removeLast() }
            if cost.hasSuffix(".") { cost.removeLast() }
            s += ",\n  \"prompter\": {\"enabled\": \(stats.enabled), \"connection\": \(JSONText.quoted(stats.connection)), \"llm_model\": \(JSONText.quoted(stats.llmModel)), \"turns\": \(stats.turns), \"prompt_tokens\": \(stats.promptTokens), \"cached_tokens\": \(stats.cachedTokens), \"completion_tokens\": \(stats.completionTokens), \"cost_usd\": \(cost), \"first_card_ms_median\": \(stats.firstCardMsMedian.map(String.init) ?? "null")}"
        }
        if let goalResult {
            s += ",\n  \"outcome\": {\"goal_result\": \(JSONText.quoted(goalResult.rawValue))}"
        }
        s += "\n}\n"
        return Data(s.utf8)
    }

    /// JSONSerialization; неизвестные ключи игнорировать.
    public static func decode(_ data: Data) throws -> CallRecord {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        let version = obj["version"] as? Int
        guard version == Self.version else { throw DecodeError.version(version) }
        guard let callID = obj["call_id"] as? String else { throw DecodeError.field("call_id") }
        guard let startedText = obj["started_at"] as? String, let startedAt = isoParser.date(from: startedText) else {
            throw DecodeError.field("started_at")
        }
        guard let model = obj["model"] as? String else { throw DecodeError.field("model") }
        guard let channels = obj["channels"] as? [String: String] else { throw DecodeError.field("channels") }
        var record = CallRecord(callID: callID, startedAt: startedAt, model: model, channels: channels)
        record.endedAt = (obj["ended_at"] as? String).flatMap(isoParser.date(from:))
        record.durationSec = (obj["duration_sec"] as? NSNumber)?.doubleValue
        record.mode = obj["mode"] as? String ?? "vks"
        record.brief = obj["brief"] as? String
        let devices = obj["devices"] as? [String: Any] ?? [:]
        record.inputDevice = devices["input"] as? String
        record.outputDevice = devices["output"] as? String
        if let app = devices["app"] as? [String: Any],
           let name = app["name"] as? String, let bundleID = app["bundle_id"] as? String,
           let pid = (app["pid"] as? NSNumber)?.int32Value {
            record.app = App(name: name, bundleID: bundleID, pid: pid)
        }
        record.recording = obj["recording"] as? String
        record.meetingID = obj["meeting_id"] as? String
        record.briefDir = obj["brief_dir"] as? String
        if let stats = obj["prompter"] as? [String: Any] {
            record.prompter = PrompterStats(
                enabled: stats["enabled"] as? Bool ?? false,
                connection: stats["connection"] as? String ?? "",
                llmModel: stats["llm_model"] as? String ?? "",
                turns: (stats["turns"] as? NSNumber)?.intValue ?? 0,
                promptTokens: (stats["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                cachedTokens: (stats["cached_tokens"] as? NSNumber)?.intValue ?? 0,
                completionTokens: (stats["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                costUSD: (stats["cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                firstCardMsMedian: (stats["first_card_ms_median"] as? NSNumber)?.intValue)
        }
        record.goalResult = (obj["outcome"] as? [String: Any])?["goal_result"].flatMap { ($0 as? String).flatMap(GoalResult.init(rawValue:)) }
        return record
    }
}

public enum CallStore {
    /// ~/ASR/Prompter/calls
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("ASR/Prompter/calls", isDirectory: true)
    }

    public static func folder(root: URL, callID: String) -> URL {
        root.appendingPathComponent(callID, isDirectory: true)
    }

    private static func file(root: URL, callID: String) -> URL {
        folder(root: root, callID: callID).appendingPathComponent(CallRecord.fileName)
    }

    /// mkdir; tmp + rename.
    public static func write(_ record: CallRecord, root: URL) throws {
        let fm = FileManager.default
        let dir = folder(root: root, callID: record.callID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = file(root: root, callID: record.callID)
        let tmp = dir.appendingPathComponent(".\(CallRecord.fileName).\(UUID().uuidString).tmp")
        try record.encoded().write(to: tmp)
        guard rename(tmp.path, target.path) == 0 else {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    public static func read(root: URL, callID: String) -> CallRecord? {
        guard let data = try? Data(contentsOf: file(root: root, callID: callID)) else { return nil }
        return try? CallRecord.decode(data)
    }

    /// По startedAt убыв.
    public static func list(root: URL) -> [CallRecord] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return dirs.compactMap { read(root: root, callID: $0.lastPathComponent) }
            .sorted { $0.startedAt == $1.startedAt ? $0.callID > $1.callID : $0.startedAt > $1.startedAt }
    }

    /// Для записей без meeting_id: <outputRoot>/<YYYY-MM из callID>/<callID>.meta.json → "meeting_id"; вернуть обновлённые callID.
    @discardableResult
    public static func reconcileMeetingIDs(root: URL, outputRoot: URL) -> [String] {
        var updated: [String] = []
        for var record in list(root: root) where record.meetingID == nil {
            guard record.callID.count >= 7 else { continue }
            let period = String(record.callID.prefix(7))
            let meta = outputRoot.appendingPathComponent(period).appendingPathComponent(record.callID + ".meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meetingID = obj["meeting_id"] as? String, !meetingID.isEmpty
            else { continue }
            record.meetingID = meetingID
            guard (try? write(record, root: root)) != nil else { continue }
            updated.append(record.callID)
        }
        return updated
    }

    // MARK: файлы суфлёра в папке звонка (§3.6) — Swift и Python пишут в append-режиме одним форматом

    private static func callFile(root: URL, callID: String, name: String) -> URL {
        folder(root: root, callID: callID).appendingPathComponent(name)
    }

    /// Дописать строку в cards.jsonl; строки атомарны при длине < PIPE_BUF.
    public static func appendCard(root: URL, callID: String, line: String) {
        let url = callFile(root: root, callID: callID, name: "cards.jsonl")
        try? FileManager.default.createDirectory(at: folder(root: root, callID: callID), withIntermediateDirectories: true)
        let chunk = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: chunk)
        } else {
            try? chunk.write(to: url)
        }
    }

    /// notes.md — заметки по ходу звонка (FR-12.8), целиком.
    public static func writeNotes(root: URL, callID: String, notes: [String]) {
        let text = notes.joined(separator: "\n") + (notes.isEmpty ? "" : "\n")
        try? FileManager.default.createDirectory(at: folder(root: root, callID: callID), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: callFile(root: root, callID: callID, name: "notes.md"))
    }

    /// outcome.json + outcome.md → CallOutcome (markdown из файла).
    public static func readOutcome(root: URL, callID: String) -> CallOutcome? {
        guard let data = try? Data(contentsOf: callFile(root: root, callID: callID, name: "outcome.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outcome = CallOutcome(json: obj["outcome"] as? [String: Any] ?? [:])
        else { return nil }
        outcome.markdown = (try? String(contentsOf: callFile(root: root, callID: callID, name: "outcome.md"), encoding: .utf8)) ?? ""
        return outcome
    }

    /// Правки итогов пользователем — перезаписать целиком.
    public static func writeOutcomeMarkdown(root: URL, callID: String, text: String) {
        try? Data(text.utf8).write(to: callFile(root: root, callID: callID, name: "outcome.md"))
    }
}
