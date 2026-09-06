import CoreMedia
import Foundation
import MLaudCore
import ScreenCaptureKit

/// Звук одного приложения через ScreenCaptureKit (порт poc/appaudio/probe/SCKCapture.swift).
/// Управление (start/stop/перезапуск/опрос pid) — на главном потоке; буферы — на `sampleQueue`.
final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Failure: Error, Equatable { case needsRestart, noContent, appGone, stream(String) }

    /// Кандидаты: bundleIdentifier непустой, pid != getpid(); сортировка по имени. −3801 → .needsRestart.
    static func candidates(completion: @escaping (Result<[CallAppCandidate], Failure>) -> Void) {
        shareableContent { result in
            switch result {
            case .failure(let failure):
                completion(.failure(failure))
            case .success(let content):
                let me = getpid()
                let apps = content.applications
                    .filter { !$0.bundleIdentifier.isEmpty && $0.processID != me }
                    .map { CallAppCandidate(pid: $0.processID, name: $0.applicationName, bundleID: $0.bundleIdentifier) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                completion(.success(apps))
            }
        }
    }

    /// SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) (SCKCapture.swift:32); ответ — на главном потоке.
    private static func shareableContent(_ completion: @escaping (Result<SCShareableContent, Failure>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            let result: Result<SCShareableContent, Failure>
            if let error {
                result = .failure(classify(error))
            } else if let content {
                result = .success(content)
            } else {
                result = .failure(.noContent)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func classify(_ error: Error) -> Failure {
        let nsError = error as NSError
        switch AppAudioPolicy.classify(errorCode: nsError.code) {
        case .needsRestart: return .needsRestart
        case .noContent: return .noContent
        case .other: return .stream("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        }
    }

    private static let outputChangeSettle: TimeInterval = 2
    private static let pidPollInterval: TimeInterval = 1

    private let onChunk: (Data) -> Void
    var onDiagnostic: ((String) -> Void)?
    var onFailure: ((Failure) -> Void)?              // главный поток
    var isRunning: Bool = false

    // Пишет поток буферов, читает главный — под замком, без обращения к очереди захвата.
    private let lock = NSLock()
    private var _lastBufferAt: Date?
    private var stopped = true
    private var emitted = Set<String>()

    private(set) var lastBufferAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _lastBufferAt }
        set { lock.lock(); _lastBufferAt = newValue; lock.unlock() }
    }

    // Только с главного потока.
    private let sampleQueue = DispatchQueue(label: "mlaud.app-audio")
    private var stream: SCStream?
    private var app: CallAppCandidate?
    private var generation = 0
    private var pidTimer: DispatchSourceTimer?
    private var outputWatch: OutputDeviceWatch?
    private var restarting = false

    init(onChunk: @escaping (Data) -> Void) {          // int16 LE 16 кГц mono, как AudioCapture
        self.onChunk = onChunk
        super.init()
    }

    deinit {
        pidTimer?.cancel()
        outputWatch?.stop()
    }

    // MARK: - Управление

    func start(app: CallAppCandidate, completion: @escaping (Failure?) -> Void) {
        teardownStream()
        self.app = app
        generation += 1
        let gen = generation
        Self.shareableContent { [weak self] result in
            guard let self, self.generation == gen else { return }
            switch result {
            case .failure(let failure):
                completion(failure)
            case .success(let content):
                self.startStream(app: app, content: content, generation: gen, completion: completion)
            }
        }
    }

    private func startStream(app: CallAppCandidate, content: SCShareableContent, generation gen: Int,
                             completion: @escaping (Failure?) -> Void) {
        guard let display = content.displays.first else {
            completion(.noContent)
            return
        }
        guard let scApp = content.applications.first(where: { $0.processID == app.pid }) else {
            completion(isAlive(pid: app.pid) ? .noContent : .appGone)
            return
        }
        // Фильтр по content.displays.first — внешний монитор не проверен (RESULT.md, C8).
        let filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            completion(Self.classify(error))
            return
        }
        lock.lock()
        stopped = false
        emitted = []
        lock.unlock()
        s.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else {
                    s.stopCapture { _ in }
                    return
                }
                if let error {
                    self.lock.lock(); self.stopped = true; self.lock.unlock()
                    completion(Self.classify(error))
                    return
                }
                self.stream = s
                self.isRunning = true
                self.lastBufferAt = Date()
                self.startPidPoll(pid: app.pid)
                self.startOutputWatch()
                self.onDiagnostic?("звук приложения: \(app.name) (pid \(app.pid)), 16000 Гц, каналов 1")
                completion(nil)
            }
        }
    }

    func stop() {
        generation += 1
        teardownStream()
        pidTimer?.cancel()
        pidTimer = nil
        outputWatch?.stop()
        outputWatch = nil
        restarting = false
        app = nil
        lastBufferAt = nil
    }

    /// Остановить поток, не трогая сторожей (для перезапуска).
    private func teardownStream() {
        lock.lock()
        stopped = true
        lock.unlock()
        isRunning = false
        guard let s = stream else { return }
        stream = nil
        try? s.removeStreamOutput(self, type: .audio)
        s.stopCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onDiagnostic?("остановка потока: \(error.localizedDescription)") }
        }
    }

    // MARK: - Сторожа

    /// Выход приложения SCK не сообщает — только опрос kill(pid, 0) (RESULT.md:91).
    private func startPidPoll(pid: Int32) {
        pidTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pidPollInterval, repeating: Self.pidPollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.stream != nil, !self.isAlive(pid: pid) else { return }
            self.stop()
            self.onFailure?(.appGone)
        }
        timer.resume()
        pidTimer = timer
    }

    private func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Смена устройства вывода: через 2 с смотрим, идут ли буферы; нет — пересобираем поток (RESULT.md:127).
    private func startOutputWatch() {
        guard outputWatch == nil else { return }
        let watch = OutputDeviceWatch { [weak self] in
            guard let self, let app = self.app else { return }
            let gen = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.outputChangeSettle) { [weak self] in
                guard let self, self.generation == gen, !self.restarting else { return }
                let age = self.lastBufferAt.map { Date().timeIntervalSince($0) }
                guard AppAudioPolicy.afterOutputChange(lastBufferAge: age) == .restart else { return }
                self.restart(app: app)
            }
        }
        watch.start()
        outputWatch = watch
    }

    private func restart(app: CallAppCandidate) {
        restarting = true
        onDiagnostic?("устройство вывода сменилось, буферов нет — пересобираю поток")
        start(app: app) { [weak self] failure in
            guard let self else { return }
            self.restarting = false
            if let failure {
                self.stop()
                self.onFailure?(failure)
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
            self.onFailure?(Self.classify(error))
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else {
            emitOnce("буфер без описания формата, отброшен")
            return
        }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, asbd.mBitsPerChannel == 32 else {
            emitOnce("формат не float32 — буферы отбрасываются")
            return
        }

        // Размер списка буферов спрашиваем у самого буфера: 8 AudioBuffer (136 байт) SCK не хватило (RESULT.md:111-113).
        var needed = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        guard sizeStatus == noErr, needed >= MemoryLayout<AudioBufferList>.size else {
            emitOnce("размер списка буферов: status=\(sizeStatus) needed=\(needed)")
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
            emitOnce("список буферов: status=\(status) needed=\(needed)")
            return
        }

        let pcm: Data? = withExtendedLifetime(blockBuffer) {
            if nonInterleaved {
                var planes: [UnsafeBufferPointer<Float>] = []
                var frames = Int.max
                for buf in abl {
                    guard let data = buf.mData else { return nil }
                    let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                    frames = min(frames, count)
                    planes.append(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                }
                guard !planes.isEmpty, frames > 0, frames != Int.max else { return nil }
                return AudioPCM.monoInt16(planes: planes, frames: frames)
            }
            let channels = Int(asbd.mChannelsPerFrame)
            guard channels > 0, abl.count >= 1, let data = abl[0].mData else { return nil }
            let count = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = count / channels
            guard frames > 0 else { return nil }
            let src = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * channels)
            return AudioPCM.monoInt16(interleaved: src, channels: channels)
        }
        guard let pcm, !pcm.isEmpty else { return }

        lock.lock()
        let dropped = stopped
        if !dropped { _lastBufferAt = Date() }
        lock.unlock()
        guard !dropped else { return }
        onChunk(pcm)
    }

    private func emitOnce(_ text: String) {
        let key = String(text.prefix { $0 != ":" && $0 != "=" })
        lock.lock()
        let inserted = emitted.insert(key).inserted
        lock.unlock()
        guard inserted else { return }
        DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(text) }
    }
}
