import AVFoundation
import Foundation
import MLaudCore

// MARK: - Помощники (только временные каталоги: вызывается после removeTestDefaults()).

/// Завершения CallRecorder приходят на главной очереди — крутим run loop, а не ждём семафор.
private func waitUntil(timeout: TimeInterval, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    return true
}

private func finishSync(_ recorder: CallRecorder, timeout: TimeInterval = 60) -> Result<CallRecorder.Output, CallRecorder.Failure>? {
    var result: Result<CallRecorder.Output, CallRecorder.Failure>?
    recorder.finish { result = $0 }
    _ = waitUntil(timeout: timeout) { result != nil }
    return result
}

private func recoverSync(_ inbox: URL, timeout: TimeInterval = 60) -> [CallRecorder.Output]? {
    var outputs: [CallRecorder.Output]?
    CallRecorder.recover(inbox: inbox) { outputs = $0 }
    _ = waitUntil(timeout: timeout) { outputs != nil }
    return outputs
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func listing(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

private func tone(hz: Double, seconds: Double, rate: Int = 16000, amplitude: Double = 0.5) -> [Int16] {
    (0..<Int(seconds * Double(rate))).map { i in
        Int16((amplitude * 32767 * sin(2 * .pi * hz * Double(i) / Double(rate))).rounded())
    }
}

/// Своё чередование каналов: CallTracks/AudioPCM пишет Swift Core, тесты записи от них не зависят.
private func interleavedPCM(left: [Int16], right: [Int16]) -> Data {
    precondition(left.count == right.count)
    var data = Data(capacity: left.count * 4)
    for i in 0..<left.count {
        for v in [left[i], right[i]] {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
    }
    return data
}

/// Энергия на частоте (Гёрцель), чтобы отличить 440 от 880 в каждом канале.
private func goertzel(_ samples: UnsafeBufferPointer<Float>, hz: Double, rate: Double) -> Double {
    let w = 2 * Double.pi * hz / rate
    let coeff = 2 * cos(w)
    var s0 = 0.0, s1 = 0.0, s2 = 0.0
    for x in samples {
        s0 = Double(x) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2
}

private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
}

private func u16(_ data: Data, _ offset: Int) -> UInt16 {
    data.subdata(in: offset..<offset + 2).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
}

private let testCallID = "2026-09-05_12-00-00"

private func makeRecorder(_ inbox: URL, callID: String = testCallID) -> CallRecorder {
    CallRecorder(inbox: inbox, callID: callID,
                 sidecar: ChannelsSidecar(callID: callID, themLabel: "Собеседник"))
}

// MARK: - Тесты

func runCallRecorderTests() {
    test("CallRecorder: порядок файлов — сайдкар, .incoming/.pcm, потом .m4a в inbox") {
        let inbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let r = makeRecorder(inbox)
        try r.start()
        let sidecar = inbox.appendingPathComponent(testCallID + ".channels.json")
        let pcm = inbox.appendingPathComponent(".incoming/\(testCallID).pcm")
        eq(r.sidecarURL, sidecar, "sidecarURL")
        eq(r.rawURL, pcm, "rawURL")
        check(exists(sidecar), "сайдкар лежит в inbox после start()")
        check(exists(pcm), ".incoming/<id>.pcm создан")
        eq(try ChannelsSidecar.decode(Data(contentsOf: sidecar)).callID, testCallID, "сайдкар читается")
        eq(InboxScanner().readyAudioFiles(in: inbox), [], "сканер inbox во время записи ничего не видит")

        r.append(interleaved: Data(repeating: 0, count: 4 * 1600))
        eq((try FileManager.default.attributesOfItem(atPath: pcm.path)[.size] as? NSNumber)?.intValue, 6400, "append дописал 6400 байт")

        let result = finishSync(r)
        guard case .success(let out)? = result else {
            check(false, "finish: \(String(describing: result))")
            return
        }
        let m4a = inbox.appendingPathComponent(testCallID + ".m4a")
        eq(out.audio, m4a, "Output.audio")
        eq(out.sidecar, sidecar, "Output.sidecar")
        check(exists(m4a), "<id>.m4a в inbox")
        eq(listing(inbox.appendingPathComponent(".incoming")), [], ".incoming пуст после finish")
        check(exists(sidecar), "сайдкар на месте")
        eq(InboxScanner().readyAudioFiles(in: inbox).map(\.lastPathComponent), [m4a.lastPathComponent],
           "сканер видит только .m4a")
    }

    test("CallRecorder: содержимое — L 440 Гц, R 880 Гц, стерео 16 кГц ≈ 1 с") {
        let inbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let r = makeRecorder(inbox)
        try r.start()
        let left = tone(hz: 440, seconds: 1)
        let right = tone(hz: 880, seconds: 1)
        let pcm = interleavedPCM(left: left, right: right)
        // Кусками по 0.1 с, как из захвата.
        let step = 16000 / 10 * 4
        var offset = 0
        while offset < pcm.count {
            r.append(interleaved: pcm.subdata(in: offset..<min(offset + step, pcm.count)))
            offset += step
        }
        guard case .success(let out)? = finishSync(r) else {
            check(false, "finish не удался")
            return
        }
        let file = try AVAudioFile(forReading: out.audio)
        eq(file.fileFormat.channelCount, 2, "2 канала")
        eq(file.fileFormat.sampleRate, 16000, "16000 Гц")
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        check(abs(seconds - 1) < 0.1, "длительность ≈ 1 с, получили \(seconds)")

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        check(n > 15000, "прочитано \(n) кадров")
        let l = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)
        let rch = UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)
        let l440 = goertzel(l, hz: 440, rate: 16000), l880 = goertzel(l, hz: 880, rate: 16000)
        let r440 = goertzel(rch, hz: 440, rate: 16000), r880 = goertzel(rch, hz: 880, rate: 16000)
        check(l440 > 10 * l880, "L: энергия в 440 выше, чем в 880 (\(l440) / \(l880))")
        check(r880 > 10 * r440, "R: энергия в 880 выше, чем в 440 (\(r880) / \(r440))")
    }

    test("CallRecorder: wavHeader — 44 байта RIFF/WAVE/fmt/data") {
        let h = CallRecorder.wavHeader(dataBytes: 64000)
        eq(h.count, 44, "44 байта")
        eq(String(data: h.subdata(in: 0..<4), encoding: .ascii), "RIFF", "RIFF")
        eq(u32(h, 4), 36 + 64000, "размер RIFF")
        eq(String(data: h.subdata(in: 8..<12), encoding: .ascii), "WAVE", "WAVE")
        eq(String(data: h.subdata(in: 12..<16), encoding: .ascii), "fmt ", "fmt ")
        eq(u32(h, 16), 16, "размер fmt")
        eq(u16(h, 20), 1, "PCM")
        eq(u16(h, 22), 2, "каналов 2")
        eq(u32(h, 24), 16000, "частота")
        eq(u32(h, 28), 64000, "байт в секунду")
        eq(u16(h, 32), 4, "block align")
        eq(u16(h, 34), 16, "бит на сэмпл")
        eq(String(data: h.subdata(in: 36..<40), encoding: .ascii), "data", "data")
        eq(u32(h, 40), 64000, "dataBytes в позиции 40")
        let mono = CallRecorder.wavHeader(dataBytes: 10, channels: 1, sampleRate: 48000, bitsPerSample: 16)
        eq(u16(mono, 22), 1, "mono: каналов 1")
        eq(u32(mono, 28), 96000, "mono 48 кГц: байт в секунду")
        eq(u16(mono, 32), 2, "mono: block align")
    }

    test("CallRecorder: recover доделывает .pcm с сайдкаром и убирает сирот") {
        let inbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let incoming = inbox.appendingPathComponent(".incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let fm = FileManager.default

        // 1. .pcm + сайдкар → доделать; залежавшийся .incoming/<id>.m4a — мусор, перезаписать.
        let pending = "2026-09-05_10-00-00"
        try ChannelsSidecar(callID: pending, themLabel: "Собеседник").encoded()
            .write(to: inbox.appendingPathComponent(pending + ".channels.json"))
        try interleavedPCM(left: tone(hz: 440, seconds: 0.5), right: tone(hz: 880, seconds: 0.5))
            .write(to: incoming.appendingPathComponent(pending + ".pcm"))
        try Data("мусор".utf8).write(to: incoming.appendingPathComponent(pending + ".m4a"))
        try Data("мусор".utf8).write(to: incoming.appendingPathComponent(pending + ".wav"))

        // 2. .pcm без сайдкара → удалить.
        let orphanPCM = "2026-09-05_10-01-00"
        try Data(repeating: 0, count: 400).write(to: incoming.appendingPathComponent(orphanPCM + ".pcm"))

        // 3. Сайдкар без .pcm и без .m4a → удалить.
        let orphanSidecar = "2026-09-05_10-02-00"
        try ChannelsSidecar(callID: orphanSidecar, themLabel: "Собеседник").encoded()
            .write(to: inbox.appendingPathComponent(orphanSidecar + ".channels.json"))

        // 4. Сайдкар с готовым .m4a → не трогать.
        let done = "2026-09-05_10-03-00"
        try ChannelsSidecar(callID: done, themLabel: "Собеседник").encoded()
            .write(to: inbox.appendingPathComponent(done + ".channels.json"))
        try Data("готово".utf8).write(to: inbox.appendingPathComponent(done + ".m4a"))

        guard let outputs = recoverSync(inbox) else {
            check(false, "recover не завершился")
            return
        }
        eq(outputs, [CallRecorder.Output(audio: inbox.appendingPathComponent(pending + ".m4a"),
                                         sidecar: inbox.appendingPathComponent(pending + ".channels.json"))],
           "восстановлен ровно один звонок")
        let recovered = inbox.appendingPathComponent(pending + ".m4a")
        check(exists(recovered), "1: .m4a появился в inbox")
        let file = try AVAudioFile(forReading: recovered)
        eq(file.fileFormat.channelCount, 2, "1: перезаписан настоящим стерео, а не мусором")
        check(abs(Double(file.length) / 16000 - 0.5) < 0.1, "1: длительность ≈ 0.5 с")
        check(exists(inbox.appendingPathComponent(pending + ".channels.json")), "1: сайдкар на месте")
        eq(listing(incoming), [], ".incoming пуст: 1 доделан, 2 удалён")
        check(!exists(inbox.appendingPathComponent(orphanSidecar + ".channels.json")), "3: сирота-сайдкар удалён")
        check(exists(inbox.appendingPathComponent(done + ".channels.json")), "4: сайдкар с .m4a не тронут")
        eq(try Data(contentsOf: inbox.appendingPathComponent(done + ".m4a")), Data("готово".utf8), "4: .m4a не тронут")
        check(fm.fileExists(atPath: incoming.path), ".incoming остаётся каталогом")
    }

    test("CallRecorder: abort убирает .incoming/<id>.* и сайдкар") {
        let inbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let r = makeRecorder(inbox)
        try r.start()
        r.append(interleaved: Data(repeating: 1, count: 400))
        let other = inbox.appendingPathComponent(".incoming/other.pcm")
        try Data(repeating: 0, count: 4).write(to: other)
        r.abort()
        check(!exists(inbox.appendingPathComponent(testCallID + ".channels.json")), "сайдкар удалён")
        eq(listing(inbox.appendingPathComponent(".incoming")), ["other.pcm"], "удалён только свой .pcm")
        check(r.rawURL == nil && r.sidecarURL == nil, "пути сброшены")
        r.append(interleaved: Data(repeating: 1, count: 400))
        check(!exists(inbox.appendingPathComponent(".incoming/\(testCallID).pcm")), "append после abort ничего не создаёт")
    }

    test("CallRecorder: start() без inbox → .inboxMissing") {
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let r = makeRecorder(inbox)
        do {
            try r.start()
            check(false, "start() должен бросить")
        } catch let failure as CallRecorder.Failure {
            eq(failure, .inboxMissing, "ошибка")
        }
        check(r.sidecarURL == nil && r.rawURL == nil, "ничего не создано")
        check(!exists(inbox), "inbox не создаётся сам")
    }

    test("CallRecorder: .pcm больше 4 ГБ — finish отказывает, .pcm остаётся (RIFF не вмещает)") {
        let inbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let r = makeRecorder(inbox)
        try r.start()
        let pcm = inbox.appendingPathComponent(".incoming/\(testCallID).pcm")
        // Разрежённый файл: первый размер, который RIFF уже не вмещает; на APFS места почти не занимает.
        let tooBig = UInt64(CallRecorder.maxWAVDataBytes + 1)
        eq(tooBig, UInt64(UInt32.max) - 35, "граница: UInt32.max − 36 + 1")
        let h = try FileHandle(forWritingTo: pcm)
        try h.truncate(atOffset: tooBig)
        try h.close()
        eq((try FileManager.default.attributesOfItem(atPath: pcm.path)[.size] as? NSNumber)?.uint64Value, tooBig, "размер .pcm")

        let started = Date()
        let result = finishSync(r)
        check(Date().timeIntervalSince(started) < 5, "отказ без чтения 4 ГБ (\(Date().timeIntervalSince(started)) с)")
        guard case .failure(.io(let message))? = result else {
            check(false, "ожидали .io, получили \(String(describing: result))")
            return
        }
        check(message.contains("4 ГБ"), "сообщение про 4 ГБ: \(message)")
        check(!message.contains("couldn’t be completed") && !message.contains("Failure error"), "текст ошибки, а не обёртка NSError: \(message)")
        check(exists(pcm), ".pcm оставлен")
        eq((try FileManager.default.attributesOfItem(atPath: pcm.path)[.size] as? NSNumber)?.uint64Value, tooBig, ".pcm не тронут")
        eq(listing(inbox.appendingPathComponent(".incoming")), ["\(testCallID).pcm"], "ни .wav, ни .m4a в .incoming")
        check(!exists(inbox.appendingPathComponent(testCallID + ".m4a")), "<id>.m4a в inbox не появился")
        check(exists(inbox.appendingPathComponent(testCallID + ".channels.json")), "сайдкар на месте")
        eq(InboxScanner().readyAudioFiles(in: inbox), [], "сканер inbox ничего не видит")
    }
}
