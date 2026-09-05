import AppKit
import Foundation

// Запись в пайп умершего распознавателя присылает SIGPIPE, который по умолчанию
// убивает процесс целиком. Игнорируем: ошибка придёт кодом возврата write(), и её
// разберёт DictationController, а пакетная обработка вообще не должна замечать,
// что диктовка отвалилась.
signal(SIGPIPE, SIG_IGN)

// Обычное приложение с иконкой в Dock, пока запущено (решение пользователя 2026-09-05,
// ux-app.md §1); закрытие окна его не завершает — слежение и приём работают из строки меню.
let app = NSApplication.shared

// Дымовая проверка окна «Голоса» без UI-автоматизации (ей нужен «Универсальный доступ»):
// MLaudApp --smoke-voices <каталог speakers> <python> <каталог worker> <база голосов>
if let i = CommandLine.arguments.firstIndex(of: "--smoke-voices"),
   CommandLine.arguments.count > i + 4 {
    let a = CommandLine.arguments
    exit(VoicesSmoke.run(speakersRoot: a[i + 1], python: a[i + 2],
                         workerDir: a[i + 3], voicesDir: a[i + 4]))
}

// Снимки экранов главного окна для проверки вида: MLaudApp --screenshot <каталог>.
let screenshotDirectory: URL? = {
    guard let i = CommandLine.arguments.firstIndex(of: "--screenshot"),
          CommandLine.arguments.count > i + 1 else { return nil }
    return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
}()

let delegate = AppDelegate(screenshotDirectory: screenshotDirectory)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
