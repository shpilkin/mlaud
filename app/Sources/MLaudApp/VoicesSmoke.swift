import AppKit
import Foundation
import MLaudCore

/// Дымовая проверка окна «Голоса» из командной строки (см. main.swift).
enum VoicesSmoke {
    static func run(speakersRoot: String, python: String, workerDir: String,
                    voicesDir: String) -> Int32 {
        let root = URL(fileURLWithPath: speakersRoot)
        let store = SpeakerSidecarStore(root: root)
        let runner = VoicesRunner(
            makeCommand: { args in
                WorkerCommand(
                    pythonExecutable: URL(fileURLWithPath: python),
                    workerDirectory: URL(fileURLWithPath: workerDir),
                    inboxFolder: URL(fileURLWithPath: workerDir),
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
        let controller = VoicesWindowController(store: store, runner: runner) { changes += 1 }
        // Раскладка без показа окна: размер задан, layout принудительный.
        controller.window?.setContentSize(NSSize(width: 880, height: 560))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))   // list --json вернулся
        let before = controller.smokeReport()
        print("после открытия: \(before)")

        guard controller.smokeDismissFirstPending() else {
            print("к разметке нечего — путь действия не проверен")
            return 2
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))   // assign --none + reload
        let after = controller.smokeReport()
        print("после «оставить без имени»: \(after)")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        print("onChange вызван раз: \(changes)")
        // Из вкладки «Люди» к кластеру образца: та же запись, что в списке.
        let source = controller.smokeReport().contains("recordings=1") ? store.recent().first?.sidecar.source : nil
        let label = store.recent().first?.sidecar.clusters.first?.label
        let revealOK = source != nil && label != nil && controller.smokeReveal(source: source!, label: label!)
        print("переход из образца к кластеру: \(revealOK)")
        let widthOK = controller.smokeReport().range(of: #"cardsWidth=(\d+)/\1 "#,
                                                     options: .regularExpression) != nil
        print("ширина карточек = ширине clip view: \(widthOK)")
        return changes == 1 && !after.contains("busy=true") && widthOK && revealOK ? 0 : 1
    }
}
