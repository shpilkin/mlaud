import AppKit

// Меню-бар приложение без иконки в Dock (accessory).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
