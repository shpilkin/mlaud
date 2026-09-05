import AppKit
import Foundation

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
        for (suffix, name) in appearances {
            for section in AppSection.allCases {
                jobs.append(Job(file: "\(section.fileName)-\(suffix)", appearance: name) {
                    $0.section = section
                    $0.voices.tab = .label
                })
                if section == .voices {
                    jobs.append(Job(file: "4b-voices-people-\(suffix)", appearance: name) {
                        $0.section = .voices
                        $0.voices.tab = .people
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
