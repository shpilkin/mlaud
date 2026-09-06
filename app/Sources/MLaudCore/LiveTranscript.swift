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
    /// в два канала по пометке голоса; неопознанные короткие — «?»).
    public func apply(_ ch: CallChannel, _ event: ChannelEvent, label: String?) {
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
                write(Self.encodeLine(ch: ch, label: lineLabel, t0: line.t0, t1: line.t1, text: line.text))
            }
        case .error:
            return
        }
        generations[ch] = gen
        let tail = gen.commits.isEmpty ? gen.preview : (gen.preview.isEmpty ? gen.commits : gen.commits + " " + gen.preview)
        tails[ch] = tail.isEmpty ? nil : tail
        onChange?()
    }

    /// Строка §3.3 без "\n".
    public static func encodeLine(ch: CallChannel, label: String, t0: Double, t1: Double, text: String) -> String {
        "{\"ch\":\(JSONText.quoted(ch.rawValue)),\"label\":\(JSONText.quoted(label)),"
            + "\"t0\":\(JSONText.number(t0)),\"t1\":\(JSONText.number(t1)),\"text\":\(JSONText.quoted(text))}"
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
