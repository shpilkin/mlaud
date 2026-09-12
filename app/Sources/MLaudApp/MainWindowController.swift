import AppKit
import SwiftUI

/// Главное окно: `NSWindow` + `NSHostingView`, разделы — в `AppModel.section`.
///
/// Приложение всегда `.regular` (иконка в Dock, главное меню; решение пользователя
/// 2026-09-05). Закрытие окна его не завершает — оно остаётся в Dock и в строке меню и
/// продолжает следить за папкой; клик по иконке в Dock открывает окно снова.
@MainActor
final class MainWindowController: NSWindowController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MLaud"
        window.minSize = NSSize(width: 960, height: 640)
        window.setFrameAutosaveName("MLaudMainWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let hosting = NSHostingView(rootView: MainView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        super.init(window: window)
        if !window.setFrameUsingName("MLaudMainWindow") {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Показать окно (и раздел, если задан). Активация — по клику в строке меню или по
    /// баннеру, то есть по воле пользователя, поэтому `ignoringOtherApps` уместен.
    ///
    /// `nonisolated` + `assumeIsolated`: вызывающие (`AppDelegate`, режим снимков) не
    /// изолированы на главный актор, но работают в главном потоке.
    nonisolated func show(section: AppSection? = nil) {
        MainActor.assumeIsolated {
            if let section { model.section = section }
            NSApp.activate(ignoringOtherApps: true)
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated var isVisible: Bool {
        MainActor.assumeIsolated { window?.isVisible ?? false }
    }

    @objc func selectSection(_ sender: NSMenuItem) {
        guard let section = AppSection(rawValue: sender.tag) else { return }
        show(section: section)
    }
}

/// Главное меню приложения. Без него `.regular`-приложение показывает пустую строку меню,
/// а ⌘C/⌘V/⌘A в полях SwiftUI не работают: они идут через цепочку ответчиков из меню «Правка».
enum MainMenu {
        static func build(delegate: AppDelegate, windowController: MainWindowController) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "MLaud")
        appMenu.addItem(withTitle: "О программе MLaud",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = delegate
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть MLaud", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Скрыть остальные",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить MLaud", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let file = NSMenu(title: "Файл")
        // Этап 4 (§4.6): новый бриф ⌘N — только в разделе «Суфлёр» (валидация по секции).
        let newBrief = NSMenuItem(title: "Новый бриф…", action: Selector(("newBriefMenu")), keyEquivalent: "n")
        newBrief.target = delegate
        file.addItem(newBrief)
        file.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let view = NSMenu(title: "Вид")
        for (index, section) in AppSection.shortcuts.enumerated() {
            let item = NSMenuItem(title: section.title, action: #selector(MainWindowController.selectSection(_:)),
                                  keyEquivalent: String(index + 1))
            item.tag = section.rawValue
            item.target = windowController
            view.addItem(item)
        }
        main.addItem(submenu(view))
        // Этап 4 (§4.6): компактная панель ⌘⇧C.
        main.addItem(NSMenuItem(title: "Компактный режим", action: Selector(("toggleCompactPanel")), keyEquivalent: "C"))

        let actions = NSMenu(title: "Действия")
        // ⌘R контекстный (D5): заголовок и действие подставляет `AppDelegate.validateMenuItem`.
        let process = NSMenuItem(title: "Обработать сейчас", action: #selector(AppDelegate.primaryAction), keyEquivalent: "r")
        process.target = delegate
        actions.addItem(process)
        let call = NSMenuItem(title: "Суфлёр: начать звонок…", action: #selector(AppDelegate.startCallSetup), keyEquivalent: "")
        call.target = delegate
        actions.addItem(call)
        // Этап 4 (§4.6): ⌘↩ валиден при идущем звонке; валидацию делает AppDelegate.
        let hint = NSMenuItem(title: "Суфлёр: подсказать", action: #selector(AppDelegate.requestHint), keyEquivalent: "\r")
        hint.target = delegate
        actions.addItem(hint)
        // Этап 5: ретро-исправление метки — последняя фраза в «не я» (клик по строке ленты).
        let markThem = NSMenuItem(title: "Суфлёр: последняя фраза — собеседник",
                                  action: #selector(AppDelegate.markLastTranscriptLineThem), keyEquivalent: "s")
        markThem.keyEquivalentModifierMask = [.command, .shift]
        markThem.target = delegate
        actions.addItem(markThem)
        let dictation = NSMenuItem(title: "Диктовка: начать / закончить", action: #selector(AppDelegate.toggleDictation), keyEquivalent: "")
        dictation.target = delegate
        actions.addItem(dictation)
        main.addItem(submenu(actions))

        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Масштабировать", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let open = NSMenuItem(title: "Открыть MLaud", action: #selector(AppDelegate.openMainWindow), keyEquivalent: "")
        open.target = delegate
        windowMenu.addItem(open)
        main.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
