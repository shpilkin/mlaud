import AppKit
import Foundation
import MLaudCore
import SwiftUI

/// Дымовая проверка раздела «Голоса» из командной строки (см. main.swift): реальный сайдкар,
/// реальный worker, экран собирается на этих данных без показа окна.
enum VoicesSmoke {
    static func run(speakersRoot: String, python: String, workerDir: String,
                    voicesDir: String) -> Int32 {
        setlinebuf(stdout)   // вывод в пайп — построчно, иначе при зависании не видно, где
        let root = URL(fileURLWithPath: speakersRoot)
        let store = SpeakerSidecarStore(root: root)
        let pythonURL = URL(fileURLWithPath: python).standardizedFileURL
        let workerURL = URL(fileURLWithPath: workerDir, isDirectory: true).standardizedFileURL
        print("python: \(pythonURL.path) · worker: \(workerURL.path) · cwd: \(FileManager.default.currentDirectoryPath)")
        let runner = VoicesRunner(
            makeCommand: { args in
                WorkerCommand(
                    pythonExecutable: pythonURL,
                    workerDirectory: workerURL,
                    inboxFolder: workerURL,
                    // Для бандла: site-packages лежат отдельно от worker'а.
                    additionalPythonPath: (ProcessInfo.processInfo.environment["PYTHONPATH"] ?? "")
                        .split(separator: ":").map { URL(fileURLWithPath: String($0)) },
                    extraEnvironment: ["MLAUD_VOICES_DIR": voicesDir,
                                       "MLAUD_SERVICE": root.deletingLastPathComponent().path],
                    module: "mlaud_worker.voices",
                    moduleArguments: args)
            },
            log: { print("  worker: \($0.split(separator: "\n").first ?? "")") }
        )
        var changes = 0
        var errors: [String] = []
        let voices = VoicesModel(store: store, runner: runner) { changes += 1 }
        voices.presentError = { message in
            errors.append(message)
            print("  ошибка worker'а: \(message.split(separator: "\n").last ?? "")")
        }
        voices.reload()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))   // list --json вернулся
        let before = voices.smokeReport()
        print("после открытия: \(before)")

        // Экран на этих данных: рендер в картинку ловит падения в теле представления
        // (индексы клипов, пустые списки) без окна и «Универсального доступа».
        let renderedSize = MainActor.assumeIsolated { render(voices) }
        print("экран отрисован: \(renderedSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "нет")")

        guard voices.dismissFirstPending() else {
            print("к разметке нечего — путь действия не проверен")
            return 2
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))   // assign --none + reload
        let after = voices.smokeReport()
        print("после «оставить без имени»: \(after)")
        print("onChange вызван раз: \(changes)")
        // Из вкладки «Люди» к кластеру образца: сначала в выбранную запись, затем в другую с
        // теми же метками кластеров — выбор и подсветка должны переехать вместе.
        func reveal(_ rec: SpeakerRecording) -> Bool {
            voices.tab = .people
            let label = rec.sidecar.clusters[0].label
            return voices.reveal(source: rec.sidecar.source, label: label)
                && voices.tab == .label
                && voices.selected?.url == rec.url
                && voices.highlighted == label
                && voices.visibleClusters.contains { $0.label == label }
        }
        let recordings = store.recent()
        let revealOK = recordings.first.map(reveal) ?? false
        print("переход из образца к кластеру: \(revealOK)")
        let crossOK = recordings.count > 1 ? reveal(recordings[1]) : false
        print("переход к другой записи с теми же метками: \(crossOK)"
              + (recordings.count > 1 ? "" : " (в каталоге одна запись)"))
        let ok = changes == 1 && errors.isEmpty && !after.contains("busy=true")
            && after.contains("pending=0") && renderedSize != nil && revealOK && crossOK
        return ok ? 0 : 1
    }

    @MainActor
    private static func render(_ voices: VoicesModel) -> CGSize? {
        let settings = SettingsModel(store: SettingsStore(defaults: UserDefaults(suiteName: "mlaud.smoke-voices")!))
        let model = AppModel(settings: settings, voices: voices)
        let renderer = ImageRenderer(content: VoicesScreen(model: model).frame(width: 880, height: 560))
        renderer.proposedSize = ProposedViewSize(width: 880, height: 560)
        guard let image = renderer.nsImage, image.size.width > 0 else { return nil }
        return image.size
    }
}
