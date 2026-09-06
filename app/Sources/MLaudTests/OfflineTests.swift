import Foundation
import MLaudCore

/// Тесты этапа 5: офлайн-режим — маршрутизация фраз по голосу, протокол с voice,
/// моно-запись без сайдкара, recover по маркеру каналов.

/// Как finishSync в CallRecorderTests: комплишены приходят на главную — крутим RunLoop.
private func spinUntil(timeout: TimeInterval = 60, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    return true
}

func runOfflineTests() {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("worker/tests/fixtures", isDirectory: true)

    test("OfflineVoicePolicy: свои — Я, чужие — не я, короткие — ?") {
        let mine = ChannelPhrase(phrase: 1, t0: 0, t1: 3, text: "я", reason: "silence",
                                 windowSec: 3, decodes: 1, voice: VoiceMark(isSelf: true, score: 0.71))
        let theirs = ChannelPhrase(phrase: 2, t0: 3, t1: 6, text: "он", reason: "silence",
                                   windowSec: 3, decodes: 1, voice: VoiceMark(isSelf: false, score: 0.31))
        let short = ChannelPhrase(phrase: 3, t0: 6, t1: 7.4, text: "угу", reason: "silence",
                                  windowSec: 1.4, decodes: 1, voice: nil)
        eq(OfflineVoicePolicy.route(mine).ch, .me, "свой — канал я")
        eq(OfflineVoicePolicy.route(mine).label, "Я", "метка Я")
        eq(OfflineVoicePolicy.route(theirs).ch, .them, "чужой — канал собеседника")
        eq(OfflineVoicePolicy.route(theirs).label, "не я", "метка без имени")
        eq(OfflineVoicePolicy.route(short).ch, .me, "короткий не перекладывается")
        eq(OfflineVoicePolicy.route(short).label, "?", "короткий — без метки")
    }

    test("ChannelCommand.open: байты с voice и без (совместимость)") {
        eq(ChannelCommand.open(ch: "me", label: "Я").line(),
           #"{"t":"open","ch":"me","label":"Я"}"#, "без флага — байты прежние")
        eq(ChannelCommand.open(ch: "me", label: "Я", voice: true).line(),
           #"{"t":"open","ch":"me","label":"Я","voice":true}"#, "флаг в конце команды")
    }

    test("RecognizerEvent.parse: поле voice в phrase") {
        let line = #"{"ch":"me","t":"phrase","phrase":1,"t0":0,"t1":3,"text":"я","reason":"silence","window_sec":3,"decodes":1,"voice":{"self":true,"score":0.71}}"#
        guard case .channel("me", .phrase(let phrase))? = RecognizerEvent.parse(line: line) else {
            check(false, "phrase не разобрался"); return
        }
        eq(phrase.voice, VoiceMark(isSelf: true, score: 0.71), "пометка голоса")
        let unmarked = #"{"ch":"me","t":"phrase","phrase":2,"t0":3,"t1":4,"text":"угу","reason":"silence","window_sec":1,"decodes":1}"#
        guard case .channel("me", .phrase(let short))? = RecognizerEvent.parse(line: unmarked) else {
            check(false, "phrase без voice не разобрался"); return
        }
        check(short.voice == nil, "без поля — nil")
    }

    test("LiveTranscript: метка строки переопределяется (офлайн)") {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = LiveTranscript(labels: [.me: "Я", .them: "не я"], fileURL: file)
        transcript.open(.me, offset: 0)
        let phrase = ChannelPhrase(phrase: 1, t0: 0, t1: 3, text: "не моё", reason: "silence",
                                   windowSec: 3, decodes: 1,
                                   voice: VoiceMark(isSelf: false, score: 0.3))
        transcript.apply(.them, .phrase(phrase), label: "не я")
        eq(transcript.lines.last?.ch, .them, "реплика легла в канал собеседника")
        eq(transcript.lines.last?.label, "не я", "метка переопределена")
        let text = try String(contentsOf: file, encoding: .utf8)
        check(text.contains(#""label":"не я""#), "файл с переопределённой меткой")
    }

    test("CallRecorder: моно без сайдкара — wav 1 канал, m4a в inbox, сайдкара нет") {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let inbox = tmp.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let recorder = CallRecorder(inbox: inbox, callID: "2026-09-06_12-00-00", sidecar: nil,
                                    sampleRate: 16000, channels: 1,
                                    afconvert: URL(fileURLWithPath: "/usr/bin/afconvert"))
        try recorder.start()
        // 0.5 с моно int16; содержимое не важно — важен путь конвертации
        recorder.append(interleaved: Data(repeating: 0x11, count: 16000))
        var finished: Result<CallRecorder.Output, CallRecorder.Failure>?
        recorder.finish { result in finished = result }
        check(spinUntil { finished != nil }, "finish завершился")
        guard case .success(let output)? = finished else {
            check(false, "моно finish не удался: \(String(describing: finished))"); return
        }
        check(FileManager.default.fileExists(atPath: output.audio.path), "m4a в inbox")
        check(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("2026-09-06_12-00-00.channels.json").path),
              "сайдкара нет — конвейер пойдёт штатной диаризацией (FR-12.11, 5.4)")
        // wav удалён после конвертации; проверим заголовок через повторную запись
        let wav = tmp.appendingPathComponent("check.wav")
        try CallRecorder.wavHeader(dataBytes: 16000, channels: 1).write(to: wav)
        let head = try Data(contentsOf: wav).prefix(44)
        eq(Int(head[22]), 1, "каналов в заголовке — 1")
    }

    test("CallRecorder.recover: моно .pcm доделывается по маркеру, сирота удаляется") {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let inbox = tmp.appendingPathComponent("inbox", isDirectory: true)
        let incoming = inbox.appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        // моно-сирота с маркером: .pcm + .chan=1
        let pcm = incoming.appendingPathComponent("2026-09-06_13-00-00.pcm")
        try Data(repeating: 0x11, count: 8000).write(to: pcm)
        try Data("1".utf8).write(to: incoming.appendingPathComponent("2026-09-06_13-00-00.chan"))
        // стерео-сирота без сайдкара и маркера — удаляется
        try Data(repeating: 0x11, count: 8000).write(to: incoming.appendingPathComponent("orphan.pcm"))

        var outputs: [CallRecorder.Output]?
        CallRecorder.recover(inbox: inbox) { result in outputs = result }
        check(spinUntil { outputs != nil }, "recover завершился")
        eq(outputs?.count, 1, "доделан только моно по маркеру")
        check(outputs?.first?.audio.lastPathComponent == "2026-09-06_13-00-00.m4a", "m4a из моно")
        check(!FileManager.default.fileExists(atPath: incoming.appendingPathComponent("orphan.pcm").path),
              "сирота без маркера удалён")
    }
}
