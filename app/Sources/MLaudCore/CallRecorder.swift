import Foundation

/// Запись звонка: сайдкар → `.incoming/<id>.pcm` → `.m4a` в inbox (§3.1, ADR-026).
/// В MLaudCore ради тестируемости (Package.swift: MLaudTests видит только MLaudCore).
/// Завершения `finish`/`recover` приходят на главной очереди, как у `AudioCapture`.
public final class CallRecorder {
    public struct Output: Equatable {
        public let audio: URL
        public let sidecar: URL

        public init(audio: URL, sidecar: URL) {
            self.audio = audio
            self.sidecar = sidecar
        }
    }

    public enum Failure: Error, Equatable { case inboxMissing, io(String), afconvert(String) }

    public static let incomingDirectory = ".incoming"

    public let inbox: URL
    public let callID: String
    public let sidecar: ChannelsSidecar
    public let sampleRate: Int
    public let afconvert: URL
    public private(set) var sidecarURL: URL?
    public private(set) var rawURL: URL?                 // <inbox>/.incoming/<callID>.pcm — interleaved int16 стерео без заголовка

    private static let workQueue = DispatchQueue(label: "mlaud.call-recorder", qos: .utility)

    // Ручка и её состояние: пишет главный поток (append), закрывает фон (finish/abort).
    private let lock = NSLock()
    private var handle: FileHandle?
    private var closed = false
    private var writeError: String?

    public init(inbox: URL, callID: String, sidecar: ChannelsSidecar, sampleRate: Int = 16000,
                afconvert: URL = URL(fileURLWithPath: "/usr/bin/afconvert")) {
        self.inbox = inbox
        self.callID = callID
        self.sidecar = sidecar
        self.sampleRate = sampleRate
        self.afconvert = afconvert
    }

    deinit {
        lock.lock()
        try? handle?.close()
        lock.unlock()
    }

    // MARK: - Пути

    private var incomingDir: URL { Self.incomingDir(inbox: inbox) }
    private var pcmURL: URL { Self.pcmURL(inbox: inbox, callID: callID) }
    private var wavURL: URL { incomingDir.appendingPathComponent(callID + ".wav") }
    private var tempM4AURL: URL { incomingDir.appendingPathComponent(callID + ".m4a") }
    private var finalM4AURL: URL { Self.audioURL(inbox: inbox, callID: callID) }
    private var sidecarFileURL: URL { Self.sidecarURL(inbox: inbox, callID: callID) }

    private static func incomingDir(inbox: URL) -> URL {
        inbox.appendingPathComponent(incomingDirectory, isDirectory: true)
    }

    private static func pcmURL(inbox: URL, callID: String) -> URL {
        incomingDir(inbox: inbox).appendingPathComponent(callID + ".pcm")
    }

    private static func audioURL(inbox: URL, callID: String) -> URL {
        inbox.appendingPathComponent(callID + ".m4a")
    }

    private static func sidecarURL(inbox: URL, callID: String) -> URL {
        inbox.appendingPathComponent(ChannelsSidecar.fileName(callID: callID))
    }

    // MARK: - Запись

    /// 1) сайдкар atomic (tmp + rename) в inbox; 2) mkdir .incoming; 3) создать .pcm.
    public func start() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inbox.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.inboxMissing
        }
        do {
            try sidecar.encoded().write(to: sidecarFileURL, options: .atomic)
        } catch {
            throw Failure.io("сайдкар: \(error.localizedDescription)")
        }
        sidecarURL = sidecarFileURL
        do {
            try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: pcmURL)
            guard fm.createFile(atPath: pcmURL.path, contents: nil) else {
                throw Failure.io("не создался \(pcmURL.lastPathComponent)")
            }
            let h = try FileHandle(forWritingTo: pcmURL)
            lock.lock()
            handle = h
            closed = false
            writeError = nil
            lock.unlock()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io("\(pcmURL.lastPathComponent): \(error.localizedDescription)")
        }
        rawURL = pcmURL
    }

    /// FileHandle append, без synchronize. После finish/abort поздние куски отбрасываются.
    public func append(interleaved: Data) {
        guard !interleaved.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: interleaved)
        } catch {
            if writeError == nil { writeError = error.localizedDescription }
        }
    }

    /// Закрыть ручку; вернуть первую ошибку записи, если была.
    private func closeHandle() -> String? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        try? handle?.close()
        handle = nil
        return writeError
    }

    /// Фон: .pcm → .wav (wavHeader + данные) → afconvert -f m4af -d aac → .incoming/<id>.m4a → rename <inbox>/<id>.m4a → удалить .pcm/.wav.
    public func finish(completion: @escaping (Result<Output, Failure>) -> Void) {
        Self.workQueue.async {
            let result: Result<Output, Failure>
            if let error = self.closeHandle() {
                result = .failure(.io(error))
            } else {
                result = self.convertOnQueue()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Удалить .incoming/<id>.* и сайдкар.
    public func abort() {
        _ = closeHandle()
        let fm = FileManager.default
        for url in [pcmURL, wavURL, tempM4AURL] {
            try? fm.removeItem(at: url)
        }
        try? fm.removeItem(at: sidecarFileURL)
        rawURL = nil
        sidecarURL = nil
    }

    /// Вся конвертация; вызывается с workQueue. Ручка уже закрыта.
    private func convertOnQueue() -> Result<Output, Failure> {
        let fm = FileManager.default
        let output = Output(audio: finalM4AURL, sidecar: sidecarFileURL)
        guard fm.fileExists(atPath: pcmURL.path) else {
            return .failure(.io("нет \(pcmURL.lastPathComponent)"))
        }
        // Крах между rename и уборкой: .m4a уже в inbox — это данные пользователя, не переписывать.
        if fm.fileExists(atPath: finalM4AURL.path) {
            try? fm.removeItem(at: wavURL)
            try? fm.removeItem(at: tempM4AURL)
            try? fm.removeItem(at: pcmURL)
            return .success(output)
        }
        try? fm.removeItem(at: wavURL)
        try? fm.removeItem(at: tempM4AURL)
        do {
            try writeWAV(from: pcmURL, to: wavURL)
        } catch let failure as Failure {
            try? fm.removeItem(at: wavURL)
            return .failure(failure)
        } catch {
            try? fm.removeItem(at: wavURL)
            return .failure(.io("wav: \(error.localizedDescription)"))
        }
        if let error = runAfconvert(input: wavURL, output: tempM4AURL) {
            try? fm.removeItem(at: wavURL)
            try? fm.removeItem(at: tempM4AURL)
            return .failure(.afconvert(error))
        }
        do {
            try fm.moveItem(at: tempM4AURL, to: finalM4AURL)
        } catch {
            try? fm.removeItem(at: wavURL)
            try? fm.removeItem(at: tempM4AURL)
            return .failure(.io("rename: \(error.localizedDescription)"))
        }
        // Сначала .wav, потом .pcm: при крахе посреди уборки остаётся источник для recover.
        try? fm.removeItem(at: wavURL)
        try? fm.removeItem(at: pcmURL)
        return .success(output)
    }

    /// Предел RIFF (UInt32 минус 36 байт заголовка): afconvert верит полю размера, урезанный заголовок дал бы .m4a из хвоста.
    public static let maxWAVDataBytes = Int(UInt32.max) - 36

    private func writeWAV(from pcm: URL, to wav: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: pcm.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxWAVDataBytes else {
            throw Failure.io("\(pcm.lastPathComponent) больше 4 ГБ — WAV не вмещает, файл оставлен в \(Self.incomingDirectory)")
        }
        let reader = try FileHandle(forReadingFrom: pcm)
        defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: wav.path, contents: nil) else {
            throw Failure.io("не создался \(wav.lastPathComponent)")
        }
        let writer = try FileHandle(forWritingTo: wav)
        defer { try? writer.close() }
        try writer.write(contentsOf: Self.wavHeader(dataBytes: size, channels: 2, sampleRate: sampleRate))
        let chunk = 1 << 20
        while true {
            let data = try reader.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try writer.write(contentsOf: data)
        }
    }

    /// nil — успех; иначе текст ошибки (stderr или код выхода).
    private func runAfconvert(input: URL, output: URL) -> String? {
        let process = Process()
        process.executableURL = afconvert
        process.arguments = ["-f", "m4af", "-d", "aac", input.path, output.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "запуск \(afconvert.path): \(error.localizedDescription)"
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "afconvert: код \(process.terminationStatus)" : text
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            return "afconvert не создал \(output.lastPathComponent)"
        }
        return nil
    }

    // MARK: - WAV

    /// 44 байта RIFF (PCM, формат 1).
    public static func wavHeader(dataBytes: Int, channels: Int = 2, sampleRate: Int = 16000, bitsPerSample: Int = 16) -> Data {
        var data = Data(capacity: 44)
        func u32(_ v: Int) {
            var x = UInt32(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func u16(_ v: Int) {
            var x = UInt16(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        let blockAlign = channels * bitsPerSample / 8
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * blockAlign)
        u16(blockAlign)
        u16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return data
    }

    // MARK: - Восстановление

    /// При запуске: .incoming/<id>.pcm, у которых в inbox лежит <id>.channels.json, доделать как finish; .pcm без сайдкара — удалить;
    /// <id>.channels.json, у которого нет ни .incoming/<id>.pcm, ни <inbox>/<id>.m4a (крах между шагами 1 и 3), — удалить.
    public static func recover(inbox: URL, completion: @escaping ([Output]) -> Void) {
        workQueue.async {
            let outputs = recoverOnQueue(inbox: inbox)
            DispatchQueue.main.async { completion(outputs) }
        }
    }

    private static func recoverOnQueue(inbox: URL) -> [Output] {
        let fm = FileManager.default
        var outputs: [Output] = []
        let incoming = incomingDir(inbox: inbox)
        let pending = ((try? fm.contentsOfDirectory(atPath: incoming.path)) ?? [])
            .filter { $0.hasSuffix(".pcm") }
            .sorted()
        for name in pending {
            let callID = String(name.dropLast(".pcm".count))
            let sidecarFile = sidecarURL(inbox: inbox, callID: callID)
            guard fm.fileExists(atPath: sidecarFile.path) else {
                try? fm.removeItem(at: incoming.appendingPathComponent(name))
                continue
            }
            let sidecar = (try? Data(contentsOf: sidecarFile)).flatMap { try? ChannelsSidecar.decode($0) }
                ?? ChannelsSidecar(callID: callID, themLabel: CallChannel.them.defaultLabel)
            let recorder = CallRecorder(inbox: inbox, callID: callID, sidecar: sidecar)
            if case .success(let output) = recorder.convertOnQueue() {
                outputs.append(output)
            }
        }
        let sidecars = ((try? fm.contentsOfDirectory(atPath: inbox.path)) ?? [])
            .filter { $0.hasSuffix(ChannelsSidecar.suffix) && !$0.hasPrefix(".") }
        for name in sidecars {
            let callID = String(name.dropLast(ChannelsSidecar.suffix.count))
            let hasPCM = fm.fileExists(atPath: pcmURL(inbox: inbox, callID: callID).path)
            let hasAudio = fm.fileExists(atPath: audioURL(inbox: inbox, callID: callID).path)
            if !hasPCM, !hasAudio {
                try? fm.removeItem(at: inbox.appendingPathComponent(name))
            }
        }
        return outputs
    }
}
