import CoreMedia
import Foundation
import ScreenCaptureKit

/// Ветка (б): ScreenCaptureKit с фильтром по приложению, только аудио.
final class SCKCapture: NSObject, Capturer, SCStreamOutput, SCStreamDelegate {
    private let target: Target
    private let options: CaptureOptions
    private(set) var formatDescription = "не запущен"

    private var stream: SCStream?
    private var onChunk: ((AudioChunk) -> Void)?
    private var onEvent: ((String) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    private var firstBuffer = true
    private var emitted = Set<String>()
    private var startedAt = Date()
    private let sampleQueue = DispatchQueue(label: "sck.audio")

    init(target: Target, options: CaptureOptions) {
        self.target = target
        self.options = options
    }

    func start(onChunk: @escaping (AudioChunk) -> Void,
               onEvent: @escaping (String) -> Void) async throws {
        self.onChunk = onChunk
        self.onEvent = onEvent
        startedAt = Date()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw ProbeError("SCK: нет ни одного дисплея")
        }
        let app = content.applications.first { $0.processID == target.pid }
        if let app {
            onEvent("sck_app pid=\(app.processID) bundle=\(app.bundleIdentifier) name=\(app.applicationName)")
        } else {
            let sameBundle = content.applications.filter { $0.bundleIdentifier == target.bundleID && target.bundleID != nil }
            let text = "SCK не видит pid=\(target.pid): приложений в списке \(content.applications.count), "
                + "с тем же bundle id \(sameBundle.map(\.processID)) (процесс без окон в SCK не попадает)"
            guard options.all else { throw ProbeError(text) }
            onEvent("sck_app_missing \(text)")
        }

        let filter: SCContentFilter
        if options.all {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else if let app {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            throw ProbeError("SCK: приложение не найдено")
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = options.rate
        config.channelCount = options.mono ? 1 : 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        setStream(s)
        formatDescription = "requested float32 \(options.rate) Hz \(config.channelCount)ch (actual — see EVENT sck_format)"
    }

    private func setStream(_ s: SCStream) {
        lock.lock()
        stream = s
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }
        do {
            try s.removeStreamOutput(self, type: .audio)
        } catch {
            onEvent?("sck_remove_output error=\(error)")
        }
        s.stopCapture { [weak self] error in
            if let error { self?.onEvent?("sck_stop error=\(error)") }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onEvent?("sck_stopped error=\(error)")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else {
            emitOnce("sck_no_asbd: буфер без описания формата, отброшен")
            return
        }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if firstBuffer {
            firstBuffer = false
            onEvent?("sck_format id=\(fourCC(asbd.mFormatID)) rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) "
                + "\(isFloat ? "float" : "int")\(asbd.mBitsPerChannel) \(nonInterleaved ? "non-interleaved" : "interleaved") "
                + "bytes_per_frame=\(asbd.mBytesPerFrame) flags=0x\(String(asbd.mFormatFlags, radix: 16))")
            onEvent?(String(format: "sck_first_buffer samples=%ld t=%.3f",
                            CMSampleBufferGetNumSamples(sampleBuffer), Date().timeIntervalSince(startedAt)))
        }

        // Размер списка буферов спрашиваем у самого буфера: 8 AudioBuffer (136 байт) SCK не хватило.
        var needed = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        guard sizeStatus == noErr, needed >= MemoryLayout<AudioBufferList>.size else {
            emitOnce("sck_abl_size_error status=\(sizeStatus) needed=\(needed)")
            return
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else {
            emitOnce("sck_abl_error status=\(status) needed=\(needed)")
            return
        }
        emitOnce("sck_abl buffers=\(abl.count) needed_bytes=\(needed)")

        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, asbd.mBitsPerChannel == 32 else {
            emitOnce("sck_format_unsupported: не float32, буферы отбрасываются")
            return
        }

        let chunk: AudioChunk? = withExtendedLifetime(blockBuffer) {
            if nonInterleaved {
                let channels = abl.count
                if channels != Int(asbd.mChannelsPerFrame) {
                    emitOnce("sck_buffers_mismatch asbd_channels=\(asbd.mChannelsPerFrame) buffers=\(channels)")
                }
                guard channels > 0 else { return nil }
                let frames = abl.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
                guard frames > 0 else { return nil }
                var out = [Float](repeating: 0, count: frames * channels)
                for (c, buf) in abl.enumerated() {
                    guard let data = buf.mData else { return nil }
                    let src = data.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames { out[f * channels + c] = src[f] }
                }
                return AudioChunk(samples: out, channels: channels, sampleRate: asbd.mSampleRate)
            }
            let channels = Int(asbd.mChannelsPerFrame)
            guard channels > 0, abl.count >= 1, let data = abl[0].mData else { return nil }
            let count = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = count / channels
            guard frames > 0 else { return nil }
            let src = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * channels)
            return AudioChunk(samples: Array(src), channels: channels, sampleRate: asbd.mSampleRate)
        }
        guard let chunk else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        onChunk?(chunk)
    }

    private func emitOnce(_ text: String) {
        let key = String(text.prefix { $0 != " " && $0 != ":" })
        guard emitted.insert(key).inserted else { return }
        onEvent?(text)
    }

    private func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
        return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(bytes: bytes, encoding: .ascii) ?? "\(v)" : "\(v)"
    }
}
