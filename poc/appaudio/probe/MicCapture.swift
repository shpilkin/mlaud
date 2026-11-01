import AVFoundation

/// Микрофон через AVAudioEngine, как в прототипе: нужен только для оценки эха динамиков.
/// Отдаёт float32 mono на частоте входа.
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var formatDescription = "не запущен"

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ProbeError("микрофон: нет входного формата") }
        formatDescription = "float32 \(Int(format.sampleRate)) Hz \(format.channelCount)ch"
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: n))
            onChunk(AudioChunk(samples: samples, channels: 1, sampleRate: format.sampleRate))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
