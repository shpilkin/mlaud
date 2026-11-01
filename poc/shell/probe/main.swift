import AppKit

// S3(б): переключение политики активации .accessory ↔ .regular по кругу.
//
// Проба собирается в бандл с LSUIElement=true (как настоящее приложение) и гоняет
// N циклов «окно открыто → .regular + activate → окно закрыто → .accessory».
// Два варианта: «как есть» и «с уступкой»: перед уходом в .accessory активация
// отдаётся приложению, которое было спереди до пробы (yieldActivation), а после
// возврата в .regular activate вызывается с задержкой в один тик.
//
// Каждый цикл пишет четыре факта: активны ли мы и ключевое ли окно после .regular,
// активны ли мы после .accessory (true = «призрак» с пустой строкой меню) и кто
// спереди. Журнал — в файл, потому что запускается через `open` и stdout некуда.

let cycles = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 20
let settle: TimeInterval = 0.5
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("ASR/spikes/shell/probe.log")

final class Probe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var previousFront: NSRunningApplication?
    private var lines: [String] = []

    struct Cycle {
        var regularActive = false
        var keyWindow = false
        var frontAfterRegular = ""
        var accessoryActive = false
        var frontAfterAccessory = ""
        var stuck: Bool { !regularActive || !keyWindow }
        var ghost: Bool { accessoryActive }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Probe"
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Activation probe"
        window.isReleasedWhenClosed = false
        window.center()
        previousFront = NSWorkspace.shared.frontmostApplication
        log("старт: политика \(NSApp.activationPolicy().rawValue), LSUIElement=\(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") ?? "nil"), спереди: \(front())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.runVariant(name: "как есть", yields: false) {
                self.runVariant(name: "с уступкой", yields: true) {
                    self.finish()
                }
            }
        }
    }

    private func runVariant(name: String, yields: Bool, completion: @escaping () -> Void) {
        var results: [Cycle] = []
        func step(_ i: Int) {
            guard i < cycles else {
                let stuck = results.filter(\.stuck).count
                let ghosts = results.filter(\.ghost).count
                log("ИТОГ «\(name)»: циклов \(results.count), застряло (не активны или окно не ключевое) \(stuck), призраков (активны в .accessory) \(ghosts)")
                completion()
                return
            }
            var cycle = Cycle()
            NSApp.setActivationPolicy(.regular)
            let activateAndShow = {
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
            }
            if yields {
                DispatchQueue.main.async(execute: activateAndShow)
            } else {
                activateAndShow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                cycle.regularActive = NSApp.isActive
                cycle.keyWindow = self.window.isKeyWindow
                cycle.frontAfterRegular = self.front()
                self.window.orderOut(nil)
                if yields, let prev = self.previousFront {
                    NSApp.yieldActivation(to: prev)
                }
                NSApp.setActivationPolicy(.accessory)
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    cycle.accessoryActive = NSApp.isActive
                    cycle.frontAfterAccessory = self.front()
                    results.append(cycle)
                    self.log(String(format: "%@ #%02d: regular: active=%@ key=%@ front=%@ | accessory: active=%@ front=%@",
                                    name, i + 1, cycle.regularActive ? "да" : "НЕТ", cycle.keyWindow ? "да" : "НЕТ",
                                    cycle.frontAfterRegular, cycle.accessoryActive ? "ДА" : "нет", cycle.frontAfterAccessory))
                    step(i + 1)
                }
            }
        }
        log("--- вариант «\(name)» ---")
        step(0)
    }

    private func finish() {
        log("конец: спереди \(front())")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func front() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? "МЫ" : (app?.localizedName ?? "?")
    }

    private func log(_ line: String) {
        lines.append(line)
        print(line)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Probe")
        appMenu.addItem(withTitle: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
