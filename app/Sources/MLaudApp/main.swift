import AppKit
import Foundation

// Запись в пайп умершего распознавателя присылает SIGPIPE, который по умолчанию
// убивает процесс целиком. Игнорируем: ошибка придёт кодом возврата write(), и её
// разберёт DictationController, а пакетная обработка вообще не должна замечать,
// что диктовка отвалилась.
signal(SIGPIPE, SIG_IGN)

// Меню-бар приложение без иконки в Dock (accessory).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
