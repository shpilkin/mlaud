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
        let line = #"{"ch":"me","t":"phrase","phrase":1,"t0":0,"t1":3,"text":"я","reason":"silence","window_sec":3,"decodes":1,"voice":{"self":true,"score":0.71,"speech":2.6}}"#
        guard case .channel("me", .phrase(let phrase))? = RecognizerEvent.parse(line: line) else {
            check(false, "phrase не разобрался"); return
        }
        eq(phrase.voice, VoiceMark(isSelf: true, score: 0.71, speechSec: 2.6), "пометка голоса")
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
                                   voice: VoiceMark(isSelf: false, score: 0.3, speechSec: 2.8))
        transcript.apply(.them, .phrase(phrase), label: "не я", voice: phrase.voice)
        eq(transcript.lines.last?.ch, .them, "реплика легла в канал собеседника")
        eq(transcript.lines.last?.label, "не я", "метка переопределена")
        let text = try String(contentsOf: file, encoding: .utf8)
        // журнал обязан быть валидным JSON построчно: 0.13.2 дописывал voice за скобкой
        for row in text.split(separator: "\n") {
            let data = Data(row.utf8)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                check(false, "строка журнала не JSON: \(row)"); continue
            }
            eq(obj["ch"] as? String, "them", "канал в JSON")
            let voice = obj["voice"] as? [String: Any]
            eq(voice?["self"] as? Bool, false, "voice.self в JSON")
            eq((voice?["score"] as? NSNumber)?.doubleValue, 0.3, "voice.score в JSON")
            eq((voice?["speech"] as? NSNumber)?.doubleValue, 2.8, "voice.speech в JSON")
        }
    }

    test("LiveTranscript.relabel: «Я» ↔ «не я», запись переноса в файл, порядок сохраняется") {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = LiveTranscript(labels: [.me: "Я", .them: "не я"], fileURL: file)
        transcript.open(.me, offset: 0)
        let mine = ChannelPhrase(phrase: 1, t0: 0, t1: 3, text: "кажется, я", reason: "silence",
                                 windowSec: 3, decodes: 1,
                                 voice: VoiceMark(isSelf: true, score: 0.8))
        transcript.apply(.me, .phrase(mine), label: "Я")
        let short = ChannelPhrase(phrase: 2, t0: 3, t1: 4, text: "угу", reason: "silence",
                                  windowSec: 1, decodes: 1, voice: nil)
        transcript.apply(.me, .phrase(short), label: "?")
        let id = transcript.lines[0].id
        var changes = 0
        transcript.onChange = { changes += 1 }

        let flipped = transcript.relabel(id: id)
        eq(flipped?.ch, .them, "исправленная строка — собеседник")
        eq(flipped?.label, "не я", "метка сменилась")
        eq(transcript.lines[0].ch, .them, "строка переложена в ленте")
        eq(transcript.lines[0].id, id, "id и позиция не изменились")
        eq(transcript.lines[0].text, "кажется, я", "текст не тронут")

        let back = transcript.relabel(id: id)
        eq(back?.ch, .me, "повторный клик возвращает")
        eq(back?.label, "Я", "метка вернулась")

        eq(transcript.relabel(id: transcript.lines[1].id)?.label, "не я",
           "короткая «?» тоже перекладывается")
        check(transcript.relabel(id: 999) == nil, "несуществующий id — nil")
        eq(changes, 3, "onChange на каждое исправление")

        let text = try String(contentsOf: file, encoding: .utf8)
        let rows = text.split(separator: "\n")
        eq(rows.count, 5, "две реплики и три переноса")
        check(rows[2].contains(#""t":"relabel""#) && rows[2].contains(#""from":"me""#),
              "перенос помечен и несёт прежний канал")
        check(rows[2].contains(#""label":"не я""#), "перенос несёт новую метку")
        check(rows[4].contains(#""from":"me""#) && rows[4].contains(#""text":"угу""#),
              "перенос короткой фразы опознаваем по тексту")
    }

    test("CallSession: режим без брифа — captureMode до и после prepare") {
        let session = CallSession(now: { Date() })
        eq(session.snapshot.mode, "vks", "по умолчанию ВКС")
        session.apply(.captureMode("offline"))
        eq(session.snapshot.mode, "offline", "режим задан до prepare")
        session.apply(.prepare(callID: "2026-09-12_21-00-00", title: "Звонок"))
        eq(session.snapshot.phase, .ready, "подготовка прошла")
        eq(session.snapshot.mode, "offline", "режим пережил prepare из ready")
        session.apply(.captureMode("vks"))
        eq(session.snapshot.mode, "vks", "режим меняется и в ready")
    }

    test("CallSession: режим микрофона — событие micMode и сброс новым звонком") {
        let session = CallSession(now: { Date() })
        check(session.snapshot.micMode == nil, "по умолчанию не задан")
        session.apply(.prepare(callID: "2026-09-13_20-00-00", title: "Звонок"))
        session.apply(.micMode("voiceIsolation"))
        eq(session.snapshot.micMode, "voiceIsolation", "режим доехал до снимка")
        session.apply(.stop)
        session.apply(.finalized(URL(fileURLWithPath: "/tmp/x.m4a")))
        session.apply(.dismiss)
        session.apply(.prepare(callID: "2026-09-13_21-00-00", title: "Звонок"))
        check(session.snapshot.micMode == nil, "новый звонок — режим заново")
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
