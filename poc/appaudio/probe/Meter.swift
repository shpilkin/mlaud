import Foundation

/// Уровень по каналам за окно в одну секунду: RMS и пик в dBFS, число кадров и кусков.
final class Meter {
    let label: String
    private let lock = NSLock()
    private var sumSquares: [Double] = []
    private var peak: [Float] = []
    private var frames = 0
    private var chunks = 0
    private(set) var channels = 0
    private(set) var sampleRate = 0.0
    private(set) var totalFrames = 0

    init(label: String) { self.label = label }

    func add(_ chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        if channels != chunk.channels {
            channels = chunk.channels
            sumSquares = Array(repeating: 0, count: channels)
            peak = Array(repeating: 0, count: channels)
        }
        sampleRate = chunk.sampleRate
        let n = chunk.samples.count / max(chunk.channels, 1)
        chunk.samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                for c in 0..<channels {
                    let s = p[i * channels + c]
                    sumSquares[c] += Double(s * s)
                    if abs(s) > peak[c] { peak[c] = abs(s) }
                }
            }
        }
        frames += n
        totalFrames += n
        chunks += 1
    }

    /// Строка за окно и сброс окна. `frames=0` — данные не шли.
    func flushLine() -> String {
        lock.lock(); defer { lock.unlock() }
        func db(_ x: Double) -> String { x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }
        let rms = (0..<channels).map { c in db(frames > 0 ? sqrt(sumSquares[c] / Double(frames)) : 0) }
        let pk = (0..<channels).map { c in db(Double(peak[c])) }
        let line = "\(label) rms_dbfs=[\(rms.joined(separator: ","))] peak_dbfs=[\(pk.joined(separator: ","))] frames=\(frames) chunks=\(chunks)"
        sumSquares = Array(repeating: 0, count: channels)
        peak = Array(repeating: 0, count: channels)
        frames = 0
        chunks = 0
        return line
    }
}

/// WAV PCM16, каналы как пришли; заголовок дописывается в конце.
final class WAVWriter {
    private let handle: FileHandle
    private let url: URL
    private var channels = 0
    private var sampleRate = 0
    private var dataBytes = 0
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.write(Data(count: 44))
    }

    func write(_ chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        if channels == 0 { channels = chunk.channels; sampleRate = Int(chunk.sampleRate) }
        guard chunk.channels == channels else { return }
        var pcm = Data(count: chunk.samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in chunk.samples.enumerated() {
                out[i] = Int16(max(-1, min(1, s)) * 32767)
            }
        }
        handle.write(pcm)
        dataBytes += pcm.count
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(max(channels, 1)); u32(sampleRate)
        u32(sampleRate * max(channels, 1) * 2); u16(max(channels, 1) * 2); u16(16)
        h.append("data".data(using: .ascii)!); u32(dataBytes)
        handle.seek(toFileOffset: 0)
        handle.write(h)
        try? handle.close()
    }
}
