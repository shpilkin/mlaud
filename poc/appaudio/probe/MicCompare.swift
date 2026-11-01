import AVFoundation
import Foundation

/// Проба front-end микрофона: одновременно AVCaptureSession (как MLaud: 16 кГц int16 mono)
/// и сырой AVAudioEngine-вход. Считает долю точных нулей, серии нулей ≥ 100 мс и RMS по
/// окнам 100 мс, читает режим микрофона (Control Center: 0 standard, 1 wide, 2 voice isolation).
final class MicCompare: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "miccompare.capture")
    private let lock = NSLock()
    private var capSamples: [Float] = []
    private var engSamples: [Float] = []
    private var engRate: Double = 0

    private func modes(_ tag: String) {
        if #available(macOS 12.0, *) {
            log("mic_mode \(tag): preferred=\(AVCaptureDevice.preferredMicrophoneMode.rawValue) active=\(AVCaptureDevice.activeMicrophoneMode.rawValue) (0 standard, 1 wideSpectrum, 2 voiceIsolation)")
        }
    }

    func run(seconds: Int, withCapture: Bool, withEngine: Bool) throws {
        modes("before")
        guard let device = AVCaptureDevice.default(for: .audio) else { throw ProbeError("нет микрофона") }
        log("device=\(device.localizedName) auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        if withCapture {
            let input = try AVCaptureDeviceInput(device: device)
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            session.startRunning()
            log("avcapture started running=\(session.isRunning)")
        }
        if withEngine {
            let node = engine.inputNode
            let fmt = node.inputFormat(forBus: 0)
            engRate = fmt.sampleRate
            node.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [self] buf, _ in
                guard let d = buf.floatChannelData, buf.frameLength > 0 else { return }
                let n = Int(buf.frameLength)
                let arr = Array(UnsafeBufferPointer(start: d[0], count: n))
                lock.lock(); engSamples.append(contentsOf: arr); lock.unlock()
            }
            engine.prepare()
            try engine.start()
            log("avaudioengine started format=\(fmt.sampleRate) Hz \(fmt.channelCount)ch vp=\(node.isVoiceProcessingEnabled)")
        }
        Thread.sleep(forTimeInterval: 1.0)
        modes("during")
        Thread.sleep(forTimeInterval: TimeInterval(max(seconds - 1, 1)))
        modes("end")
        if withCapture { session.stopRunning() }
        if withEngine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        lock.lock(); let cap = capSamples; let eng = engSamples; lock.unlock()
        if withCapture { report("avcapture-16k-int16", cap, 16000) }
        if withEngine { report("avaudioengine-raw", eng, engRate) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let p = ptr else { return }
        let n = length / 2
        var arr = [Float](repeating: 0, count: n)
        p.withMemoryRebound(to: Int16.self, capacity: n) { s in
            for i in 0..<n { arr[i] = Float(s[i]) / 32768 }
        }
        lock.lock(); capSamples.append(contentsOf: arr); lock.unlock()
    }

    private func report(_ label: String, _ x: [Float], _ rate: Double) {
        let n = x.count
        guard n > 0 else { log("\(label): нет данных"); return }
        var zeros = 0, runs = 0, runTotal = 0, i = 0
        let minRun = Int(rate / 10)
        while i < n {
            if x[i] == 0 {
                var j = i
                while j < n && x[j] == 0 { j += 1 }
                zeros += j - i
                if j - i >= minRun { runs += 1; runTotal += j - i }
                i = j
            } else { i += 1 }
        }
        let w = Int(rate / 10)
        var dbs: [Double] = []
        var k = 0
        while k + w <= n {
            var s = 0.0
            for t in k..<(k + w) { s += Double(x[t] * x[t]) }
            dbs.append(10 * log10(s / Double(w) + 1e-24))
            k += w
        }
        dbs.sort()
        func pct(_ p: Double) -> Double { dbs[min(dbs.count - 1, Int(Double(dbs.count - 1) * p))] }
        log(String(format: "%@: rate=%.0f dur=%.1fs zero_samples=%.1f%% zero_runs>=100ms=%d (%.1fs) rms100ms p5/p50/p95 dB=%.0f/%.0f/%.0f",
                   label, rate, Double(n) / rate, Double(zeros) / Double(n) * 100, runs, Double(runTotal) / rate,
                   pct(0.05), pct(0.5), pct(0.95)))
    }
}
