import AVFoundation

/// Захват микрофона сразу в том виде, который ест модель: 16 кГц, mono, int16.
/// Пересчёт делает AVAudioConverter — частота железа (обычно 48 кГц) заранее неизвестна
/// и меняется при смене устройства, предполагать её нельзя (тот же урок, что в ADR-014).
public final class AudioCapture {
    public enum CaptureError: Error, LocalizedError {
        case microphoneUnavailable
        case converterUnavailable
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: return "микрофон недоступен"
            case .converterUnavailable:  return "не удалось создать конвертер формата"
            case .engineFailed(let m):   return "аудиодвижок не запустился: \(m)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private let onChunk: (Data) -> Void
    private var converter: AVAudioConverter?
    public private(set) var isRunning = false

    public init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
        self.target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                    channels: 1, interleaved: true)!
    }

    /// Разрешение на микрофон. Спрашивается один раз, дальше отвечает система.
    public static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.converterUnavailable
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter?.reset()
        converter = nil
        isRunning = false
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        onChunk(Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
    }

    deinit { stop() }
}
