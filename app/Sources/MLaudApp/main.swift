import AppKit
import Foundation

// Запись в пайп умершего распознавателя присылает SIGPIPE, который по умолчанию
// убивает процесс целиком. Игнорируем: ошибка придёт кодом возврата write(), и её
// разберёт DictationController, а пакетная обработка вообще не должна замечать,
// что диктовка отвалилась.
signal(SIGPIPE, SIG_IGN)

// Меню-бар приложение без иконки в Dock (accessory).
let app = NSApplication.shared

// Дымовая проверка окна «Голоса» без UI-автоматизации (ей нужен «Универсальный доступ»):
// MLaudApp --smoke-voices <каталог speakers> <python> <каталог worker> <база голосов>
if let i = CommandLine.arguments.firstIndex(of: "--smoke-voices"),
   CommandLine.arguments.count > i + 4 {
    let a = CommandLine.arguments
    exit(VoicesSmoke.run(speakersRoot: a[i + 1], python: a[i + 2],
                         workerDir: a[i + 3], voicesDir: a[i + 4]))
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
