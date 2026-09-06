import AppKit
import Foundation
import MLaudCore

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
                        })
                    }
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
                if let view = controller.window?.contentView {
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
