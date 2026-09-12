import Foundation

/// Лента звонка: строки по фразам и хвосты каналов, дозапись `transcript.live.jsonl` (§3.3).
public final class LiveTranscript {
    private struct Generation {
        var offset: TimeInterval = 0
        var joiner = TextJoiner()
        var commits = ""
        var preview = ""
    }

    private let labels: [CallChannel: String]
    private let fileURL: URL?
    private var generations: [CallChannel: Generation] = [:]
    private var nextID = 0
    private var handle: FileHandle?
    public private(set) var lines: [TranscriptLine] = []
    public private(set) var tails: [CallChannel: String] = [:]
    public var onChange: (() -> Void)?

    public init(labels: [CallChannel: String], fileURL: URL?) {   // nil → без файла
        self.labels = labels
        self.fileURL = fileURL
    }

    deinit {
        try? handle?.close()
    }

    /// Новое поколение канала: хвост очищен, номера phrase worker'а считаются заново.
    public func open(_ ch: CallChannel, offset: TimeInterval) {
        generations[ch] = Generation(offset: offset)
        tails[ch] = nil
        onChange?()
    }

    public func apply(_ ch: CallChannel, _ event: ChannelEvent) {
        apply(ch, event, label: nil)
    }

    /// `label` — переопределить метку строки (этап 5: офлайн кладёт реплики одного микрофона
    /// в два канала по пометке голоса; неопознанные короткие — «?»). `voiceScore` — косинус
    /// к эталону «я» из события `phrase`, в журнал и только для разбора ошибок пометки.
    public func apply(_ ch: CallChannel, _ event: ChannelEvent, label: String?, voiceScore: Double? = nil) {
        var gen = generations[ch] ?? Generation()
        switch event {
        case .commit(_, let text):
            gen.commits += gen.joiner.next(text)
        case .preview(_, let text):
            gen.preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .phrase(let phrase):
            gen.commits = ""
            gen.preview = ""
            gen.joiner.reset()
            if !phrase.text.isEmpty {
                nextID += 1
                let lineLabel = label ?? labels[ch] ?? ch.defaultLabel
                let line = TranscriptLine(id: nextID, ch: ch, label: lineLabel,
                                          t0: gen.offset + phrase.t0, t1: gen.offset + phrase.t1, text: phrase.text)
                insert(line)
                write(Self.encodeLine(ch: ch, label: lineLabel, t0: line.t0, t1: line.t1,
                                      text: line.text, voice: voiceScore))
            }
        case .error:
            return
        }
        generations[ch] = gen
        let tail = gen.commits.isEmpty ? gen.preview : (gen.preview.isEmpty ? gen.commits : gen.commits + " " + gen.preview)
        tails[ch] = tail.isEmpty ? nil : tail
        onChange?()
    }

    /// Строка §3.3 без "\n"; `voice` — только у офлайн-реплик с пометкой голоса.
    public static func encodeLine(ch: CallChannel, label: String, t0: Double, t1: Double, text: String,
                                  voice: Double? = nil) -> String {
        var line = "{\"ch\":\(JSONText.quoted(ch.rawValue)),\"label\":\(JSONText.quoted(label)),"
            + "\"t0\":\(JSONText.number(t0)),\"t1\":\(JSONText.number(t1)),\"text\":\(JSONText.quoted(text))}"
        if let voice {
            line += ",\"voice\":\(JSONText.number(voice))"
        }
        return line
    }

    /// Ретро-исправление метки (этап 5): пометка голоса могла ошибиться — строку можно
    /// переложить в другой канал («Я» ↔ «не я»). Id, время и порядок ленты не меняются;
    /// в файл дописывается запись переноса. Возвращает строку в новом виде.
    @discardableResult
    public func relabel(id: Int) -> TranscriptLine? {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return nil }
        let old = lines[index]
        let target: CallChannel = old.ch == .them ? .me : .them
        let updated = TranscriptLine(id: old.id, ch: target, label: labels[target] ?? target.defaultLabel,
                                     t0: old.t0, t1: old.t1, text: old.text)
        lines[index] = updated
        write(Self.encodeRelabel(from: old.ch, to: updated))
        onChange?()
        return updated
    }

    /// Запись переноса для `transcript.live.jsonl`: у реплик в файле нет id, поэтому
    /// строка описана временем и текстом, `from` — канал до исправления.
    public static func encodeRelabel(from ch: CallChannel, to line: TranscriptLine) -> String {
        "{\"t\":\"relabel\",\"from\":\(JSONText.quoted(ch.rawValue)),\"ch\":\(JSONText.quoted(line.ch.rawValue)),"
            + "\"label\":\(JSONText.quoted(line.label)),\"t0\":\(JSONText.number(line.t0)),"
            + "\"t1\":\(JSONText.number(line.t1)),\"text\":\(JSONText.quoted(line.text))}"
    }

    /// Бинарная вставка по t0; при равенстве — после существующих.
    private func insert(_ line: TranscriptLine) {
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].t0 <= line.t0 { lo = mid + 1 } else { hi = mid }
        }
        lines.insert(line, at: lo)
    }

    private func write(_ line: String) {
        guard let fileURL else { return }
        if handle == nil {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
            _ = try? h.seekToEnd()
            handle = h
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }
}
