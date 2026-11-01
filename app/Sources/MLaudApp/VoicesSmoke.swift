import AppKit
import Foundation
import MLaudCore
import SwiftUI

/// Дымовая проверка раздела «Голоса» из командной строки (см. main.swift): реальный сайдкар,
/// реальный worker, экран собирается на этих данных без показа окна.
enum VoicesSmoke {
    /// `archive` — каталог результатов и архив аудио: с ними после основных проверок гонится
    /// «Разметить всё без сайдкара» (реальные модели, минута-другая).
    static func run(speakersRoot: String, python: String, workerDir: String,
                    voicesDir: String, archive: (outputs: String, archive: String)?) -> Int32 {
        setlinebuf(stdout)   // вывод в пайп — построчно, иначе при зависании не видно, где
        let root = URL(fileURLWithPath: speakersRoot)
        let store = SpeakerSidecarStore(root: root)
        let pythonURL = URL(fileURLWithPath: python).standardizedFileURL
        let workerURL = URL(fileURLWithPath: workerDir, isDirectory: true).standardizedFileURL
        print("python: \(pythonURL.path) · worker: \(workerURL.path) · cwd: \(FileManager.default.currentDirectoryPath)")
        // Worker пишет только во временный корень: сайдкары, база, результаты, архив.
        // Модели — из локального кеша HF, без сети.
        var environment = ["MLAUD_VOICES_DIR": voicesDir,
                           "MLAUD_SERVICE": root.deletingLastPathComponent().path,
                           "HF_HUB_OFFLINE": "1"]
        if let archive {
            environment["MLAUD_OUTPUT"] = archive.outputs
            environment["MLAUD_PROCESSED"] = archive.archive
        }
        let runner = VoicesRunner(
            makeCommand: { args in
                WorkerCommand(
                    pythonExecutable: pythonURL,
                    workerDirectory: workerURL,
                    inboxFolder: workerURL,
                    // Для бандла: site-packages лежат отдельно от worker'а.
                    additionalPythonPath: (ProcessInfo.processInfo.environment["PYTHONPATH"] ?? "")
                        .split(separator: ":").map { URL(fileURLWithPath: String($0)) },
                    extraEnvironment: environment,
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
        guard ok else { return 1 }
        guard let archive else { return 0 }
        return bulkPrepare(voices, speakersRoot: root, outputs: archive.outputs, archive: archive.archive,
                           changes: { changes }, errors: { errors }) ? 0 : 1
    }

    /// «Разметить всё без сайдкара»: кандидаты из индекса архива, подтверждение — печатью,
    /// очередь до конца, затем сайдкар, перезаписанный транскрипт и пустой список кандидатов.
    private static func bulkPrepare(_ voices: VoicesModel, speakersRoot: URL, outputs: String, archive: String,
                                    changes: () -> Int, errors: () -> [String]) -> Bool {
        let index = RecordingIndex(root: URL(fileURLWithPath: outputs, isDirectory: true),
                                   speakersRoot: speakersRoot,
                                   archiveRoot: URL(fileURLWithPath: archive, isDirectory: true))
        voices.setArchive(index.scan())
        let ready = voices.readyCandidates, noAudio = voices.noAudioCandidates
        print("кандидаты: готовы=\(ready.count) без аудио=\(noAudio.count)")
        for r in ready { print("  готова: \(r.period)/\(r.base) ← \(r.audio?.lastPathComponent ?? "-")") }
        for r in noAudio { print("  без аудио: \(r.period)/\(r.base)") }
        let renderedSize = MainActor.assumeIsolated { render(voices) }
        print("экран с кандидатами отрисован: \(renderedSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "нет")")
        guard !ready.isEmpty, renderedSize != nil else { return false }

        let textsBefore = ready.map { (try? String(contentsOf: $0.txt, encoding: .utf8)) ?? "" }
        let changesBefore = changes()
        voices.confirm = { title, message, button in
            print("подтверждение: «\(title)» [\(button)]")
            for line in message.split(separator: "\n") { print("  \(line)") }
            return true
        }
        voices.prepareAllWithoutSidecar()
        print("запущено: preparing=\(voices.isPreparing) status=«\(voices.status)»")
        let deadline = Date(timeIntervalSinceNow: 300)
        while voices.isPreparing, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        print("итог: preparing=\(voices.isPreparing) status=«\(voices.status)» onChange=\(changes())")

        var checks: [(String, Bool)] = []
        for (i, r) in ready.enumerated() {
            let sidecar = speakersRoot.appendingPathComponent("\(r.period)/\(r.base)/speakers.json")
            checks.append(("сайдкар \(r.period)/\(r.base)", FileManager.default.fileExists(atPath: sidecar.path)))
            let text = (try? String(contentsOf: r.txt, encoding: .utf8)) ?? ""
            checks.append(("транскрипт \(r.base) перезаписан", !text.isEmpty && text != textsBefore[i]))
        }
        checks.append(("очередь завершена (prepareProgress == nil)", !voices.isPreparing))
        checks.append(("ошибок worker'а нет", errors().isEmpty))
        checks.append(("onChange вызван снова", changes() > changesBefore))
        voices.setArchive(index.scan())
        checks.append(("после пересканирования готовых кандидатов нет", voices.readyCandidates.isEmpty))
        for (name, passed) in checks { print("\(passed ? "ok  " : "FAIL") \(name)") }
        return checks.allSatisfy(\.1)
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
