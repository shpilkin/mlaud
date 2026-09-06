import AppKit
import Foundation
import MLaudCore
import SwiftUI

/// `MLaudApp --screenshot <каталог>`: открыть главное окно, снять каждый раздел в светлой и
/// тёмной теме в PNG и выйти. Проверка вида без рук и без «Универсального доступа», как
/// `--smoke-voices` для окна «Голоса». Движки (слежение, диктовка, приём) в этом режиме не
/// запускаются: рядом может работать установленное приложение на той же папке.
enum Screenshots {
    static func run(window controller: MainWindowController, model: AppModel, directory: URL,
                    completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller.show(section: .overview)
        struct Job {
            let file: String
            let appearance: NSAppearance.Name
            var window: NSWindow? = nil
            let prepare: (AppModel) -> Void
        }
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        var jobs: [Job] = []
        // Настоящий список звонков (reloadRecordings, асинхронно) запоминаем перед первым подставным
        // заданием и возвращаем каждому базовому — иначе тёмный «3-prompter» рисует остаток фикстур.
        var realCalls: [CallRecord]?
        for (suffix, name) in appearances {
            for section in AppSection.allCases {
                jobs.append(Job(file: "\(section.fileName)-\(suffix)", appearance: name) {
                    $0.section = section
                    $0.voices.tab = .label
                    // Подставной звонок предыдущего задания не должен просочиться в сайдбар.
                    $0.call = CallSnapshot()
                    $0.callApps = []
                    $0.callAppPID = nil
                    if let realCalls {
                        $0.calls = realCalls
                    } else if section == .prompter {
                        realCalls = $0.calls
                    }
                })
                if section == .voices {
                    jobs.append(Job(file: "4b-voices-people-\(suffix)", appearance: name) {
                        $0.section = .voices
                        $0.voices.tab = .people
                    })
                }
                if section == .prompter {
                    // Экран звонка по фазам на подставном снимке: движков нет, контроллер не создаётся.
                    for (file, snapshot) in CallFixtures.all {
                        jobs.append(Job(file: "\(file)-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            $0.call = snapshot.call
                            $0.callApps = snapshot.apps
                            $0.callAppPID = snapshot.selected
                            $0.calls = snapshot.calls
                            $0.prompterView = .list
                        })
                    }
                    // Этап 4: редактор брифа, карточки/пауза/итоги звонка, экран итогов, компакт.
                    jobs.append(contentsOf: [
                        Job(file: "3f-brief-editor-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            $0.prompterView = .editor
                            $0.editingBriefSlug = "interview-ivan"
                            $0.editingBrief = try? BriefParser.parse(CallFixtures.briefText)
                            $0.editingMaterials = CallFixtures.materialsReport
                        },
                        Job(file: "3g-call-cards-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            $0.call = CallFixtures.runningCards.call
                            $0.callApps = CallFixtures.apps
                            $0.callAppPID = 4242
                        },
                        Job(file: "3h-call-paused-cost-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            $0.call = CallFixtures.runningCards.call
                            $0.call.prompter.status = .pausedByCost(costUSD: 0.051, ceilingUSD: 0.05)
                            $0.callApps = CallFixtures.apps
                            $0.callAppPID = 4242
                        },
                        Job(file: "3i-call-finishing-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            var call = CallFixtures.runningCards.call
                            call.phase = .finishing
                            call.prompter.outcomeState = .computing
                            $0.call = call
                        },
                        Job(file: "3j-outcome-\(suffix)", appearance: name) {
                            $0.section = .prompter
                            $0.prompterView = .outcome(callID: CallFixtures.outcomeCallID)
                            $0.calls = [CallFixtures.outcomeRecord]
                            CallFixtures.seedOutcome()
                        },
                        Job(file: "3k-compact-\(suffix)", appearance: name,
                            window: CallFixtures.compactWindow()) {
                            $0.section = .prompter
                            $0.call = CallFixtures.runningCards.call
                            let window = CallFixtures.compactWindow()
                            window.contentView = NSHostingView(rootView: CompactView(model: $0))
                            window.setContentSize(NSSize(width: 380, height: 460))
                        },
                    ])
                }
                if section == .settings {
                    jobs.append(Job(file: "8b-settings-prompter-\(suffix)", appearance: name) {
                        $0.section = .settings
                        $0.settingsTab = .prompter
                        $0.settings.connections = LLMConnection.presets
                        $0.settings.connectionHasKey = [LLMConnection.presets[0].id: true]
                        $0.settings.connectionCheck = [LLMConnection.presets[1].id: .ok(ttftMs: 2600)]
                    })
                }
            }
        }

        func step(_ i: Int) {
            guard i < jobs.count else {
                completion()
                return
            }
            let job = jobs[i]
            NSApp.appearance = NSAppearance(named: job.appearance)
            job.prepare(model)
            // Два прохода цикла: SwiftUI перерисовывает раздел и тему не в том же тике.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let view = (job.window?.contentView ?? controller.window?.contentView) {
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let url = directory.appendingPathComponent("\(job.file).png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                        print("снимок: \(url.path)")
                    }
                }
                step(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step(0) }
    }
}

/// Подставные состояния раздела «Суфлёр» для снимков: список звонков и четыре фазы экрана.
enum CallFixtures {
    struct Fixture {
        var call = CallSnapshot()
        var apps: [CallAppCandidate] = []
        var selected: Int32?
        var calls: [CallRecord] = []
    }

    static let apps = [
        CallAppCandidate(pid: 4242, name: "zoom.us", bundleID: "us.zoom.xos"),
        CallAppCandidate(pid: 4300, name: "Telegram", bundleID: "ru.keepcoder.Telegram"),
    ]

    static var all: [(String, Fixture)] {
        [("3a-prompter-list", list), ("3b-call-ready", ready), ("3c-call-running", running),
         ("3d-call-finishing", finishing), ("3e-call-done", done)]
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date()
    }

    static var list: Fixture {
        var f = Fixture()
        var first = CallRecord(callID: "2026-09-04_15-30-05", startedAt: date("2026-09-04T12:30:05Z"),
                               model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
        first.endedAt = date("2026-09-04T12:40:17Z")
        first.durationSec = 612.4
        first.recording = "2026-09-04_15-30-05.m4a"
        first.meetingID = "m-2026-09-04-01"
        var second = CallRecord(callID: "2026-09-05_10-02-40", startedAt: date("2026-09-05T07:02:40Z"),
                                model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
        second.endedAt = date("2026-09-05T07:31:03Z")
        second.durationSec = 1703
        second.recording = "2026-09-05_10-02-40.m4a"
        let third = CallRecord(callID: "2026-09-05_14-11-09", startedAt: date("2026-09-05T11:11:09Z"),
                               model: "rnnt", channels: ["0": "Я", "1": "Собеседник"])
        f.calls = [third, second, first]
        return f
    }

    private static func base(_ phase: CallPhase) -> Fixture {
        var f = Fixture()
        f.call.phase = phase
        f.call.callID = "2026-09-05_14-11-09"
        f.call.title = "Звонок"
        f.call.appName = "zoom.us"
        f.call.inputDeviceName = "MacBook Pro Microphone"
        f.call.outputDeviceName = "AirPods Pro"
        f.call.microphone = .ok
        f.call.appAudio = .ok
        f.apps = apps
        f.selected = 4242
        return f
    }

    static var ready: Fixture {
        var f = base(.ready)
        f.call.headphonesWarning = true
        f.call.outputDeviceName = "MacBook Pro Speakers"
        f.call.appAudio = .needsRestart
        f.call.recognizer = .off
        return f
    }

    static var running: Fixture {
        var f = base(.running)
        f.call.startedAt = Date().addingTimeInterval(-1122)
        f.call.elapsed = 1122
        f.call.recordedSec = 1121.5
        f.call.recognizer = .ready
        f.call.me = .flowing
        f.call.them = .noAudio("приложение закрыто")
        f.call.levels.me = 0.12
        f.call.levels.them = 0.004
        f.call.lines = [
            TranscriptLine(id: 1, ch: .them, label: "Собеседник", t0: 1111.2, t1: 1118.6,
                           text: "Расскажу про проект в X, там я отвечал за аналитику процесса и витрины для продукта."),
            TranscriptLine(id: 2, ch: .me, label: "Я", t0: 1119.0, t1: 1120.4, text: "А кто ставил задачу?"),
        ]
        f.call.tails = [.them: "Ставил продакт, но я сам предложил считать"]
        return f
    }

    static var finishing: Fixture {
        var f = base(.finishing)
        f.call.elapsed = 1130
        f.call.recordedSec = 1130
        f.call.recognizer = .ready
        f.call.me = .flowing
        f.call.them = .flowing
        f.call.lines = running.call.lines
        return f
    }

    static var done: Fixture {
        var f = base(.done)
        f.call.elapsed = 1130
        f.call.recordedSec = 1130
        f.call.recognizer = .off
        f.call.result = URL(fileURLWithPath: "/Users/me/ASR/Inbox/AllRecords/2026-09-05_14-11-09.m4a")
        return f
    }
}

// MARK: - фикстуры этапа 4: редактор, карточки, итоги, компактная панель

extension CallFixtures {
    /// ok-full из общих фикстур worker — редактор снимается на настоящем брифе.
    static var briefText: String {
        let url = URL(fileURLWithPath: #filePath)      // app/Sources/MLaudApp/Screenshots.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("worker/tests/fixtures/brief/ok-full.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "---\ntitle: Бриф\nmode: vks\n---\n"
    }

    static let materialsReport: MaterialsReport = {
        var report = MaterialsReport()
        report.materials = [
            MaterialInfo(name: "резюме.pdf", kind: "pdf", tokens: 2100),
            MaterialInfo(name: "скан.pdf", kind: "pdf", tokens: 0, warning: "нет текстового слоя, пропущен"),
            MaterialInfo(name: "план-витрин.xlsx", kind: "xlsx", tokens: 0, warning: "тип не поддерживается"),
        ]
        report.total = 2100
        report.budget = 120000
        report.over = ["большой-отчёт.docx"]
        return report
    }()

    /// Экран звонка с работающим суфлёром: карточки, повестка, вопрос висит (UX:275).
    static var runningCards: Fixture {
        var f = running
        f.call.title = "Интервью — Иван Петров, senior BA"
        var p = PrompterSnapshot()
        p.status = .ready
        p.connectionName = "DeepSeek V4 Flash (OpenRouter)"
        p.briefTitle = f.call.title
        p.briefLoaded = true
        p.contextTokens = 31400
        p.agenda = [AgendaItem(item: "Знакомство и мотивация", status: .done),
                    AgendaItem(item: "Опыт: два кейса подробно", status: .active),
                    AgendaItem(item: "Кейс-задача", status: .pending)]
        p.pinned = [PromptCard(id: "1.1", type: .answer, priority: 1,
                               text: "Спросить про метрики кейса")]
        p.cards = [
            PromptCard(id: "2.1", type: .answer, priority: 1, text: "Ответить: аналитика процесса, 6 лет"),
            PromptCard(id: "2.2", type: .fact, priority: 2, text: "В резюме: вёл команду из трёх", source: "резюме.pdf"),
            PromptCard(id: "t.50", type: .time, priority: 1, text: "Половина времени. Не начаты: Кейс-задача."),
        ]
        p.questionPending = true
        p.turns = 2
        p.lastLatencyMs = 5700
        p.lastFirstCardMs = 3400
        p.lastCachedTokens = 33024
        p.costUSD = 0.012
        p.notes = ["проверить зарплатные ожидания"]
        f.call.prompter = p
        return f
    }

    static let outcomeCallID = "2026-09-04_15-30-05"

    static var outcomeRecord: CallRecord {
        var r = CallRecord(callID: outcomeCallID, startedAt: date("2026-09-04T12:30:05Z"),
                           model: "rnnt", channels: ["0": "Я", "1": "Иван Петров"])
        r.endedAt = date("2026-09-04T12:40:17Z")
        r.durationSec = 612.4
        r.brief = "Интервью — Иван Петров, senior BA"
        r.briefDir = "interview-ivan"
        r.recording = "2026-09-04_15-30-05.m4a"
        r.meetingID = "m-1"
        r.prompter = CallRecord.PrompterStats(
            enabled: true, connection: "DeepSeek V4 Flash (OpenRouter)",
            llmModel: "deepseek/deepseek-v4-flash", turns: 7, promptTokens: 236000,
            cachedTokens: 231000, completionTokens: 2100, costUSD: 0.012, firstCardMsMedian: 3400)
        r.goalResult = .partial
        return r
    }

    /// Экран итогов читает outcome.json/outcome.md из папки звонка — сеём их в resolve().calls.
    static func seedOutcome() {
        let root = PrompterPaths.resolve().calls
        if CallStore.read(root: root, callID: outcomeCallID) == nil {
            try? CallStore.write(outcomeRecord, root: root)
        }
        let dir = CallStore.folder(root: root, callID: outcomeCallID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outcome = """
        {"version":1,"call_id":"\(outcomeCallID)","outcome":{"goal_result":"partial","reason":"кейс-задачу не успели","summary":"кандидат сильный","decisions":["дойти до кейса во второй встрече"],"next_steps":["отправить тестовое"],"open_questions":[],"assessment":[{"criterion":"системность","verdict":"да","evidence":"разложил задачу по шагам"}]},"usage":{},"cost_total_usd":0.012}
        """
        try? Data(outcome.utf8).write(to: dir.appendingPathComponent("outcome.json"))
        try? """
        # Итоги: Интервью — Иван Петров, senior BA
        Звонок \(outcomeCallID) · 2026-09-04T15:30:05+03:00 · результат по цели: частично

        кейс-задачу не успели

        ## Кратко
        кандидат сильный

        ## Решения
        - дойти до кейса во второй встрече

        ## Следующие шаги
        - отправить тестовое

        ## Оценка по критериям
        | критерий | вердикт | основание |
        | --- | --- | --- |
        | системность | да | разложил задачу по шагам |
        """.write(to: dir.appendingPathComponent("outcome.md"), atomically: true, encoding: .utf8)
    }

    /// Окно компактной панели — вне главного, снимаем его contentView (§4.6 [предложено]).
    /// Сильная ссылка: слабая умирает до захвата, и кадр берётся из главного окна.
    static func compactWindow() -> NSWindow {
        if let existing = _compactWindow { return existing }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                              styleMask: [.titled, .closable, .utilityWindow],
                              backing: .buffered, defer: false)
        window.title = "Суфлёр"
        _compactWindow = window
        return window
    }

    private static var _compactWindow: NSWindow?
}

extension AppSection {
    var fileName: String {
        switch self {
        case .overview: return "1-overview"
        case .recordings: return "2-recordings"
        case .prompter: return "3-prompter"
        case .voices: return "4-voices"
        case .dictation: return "5-dictation"
        case .phone: return "6-phone"
        case .notifications: return "7-notifications"
        case .settings: return "8-settings"
        case .styleguide: return "9-styleguide"
        }
    }
}
