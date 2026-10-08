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
//   [<каталог результатов> <архив аудио>] — с двумя последними проверяется и
//   «Разметить всё без сайдкара».
if let i = CommandLine.arguments.firstIndex(of: "--smoke-voices"),
   CommandLine.arguments.count > i + 4 {
    let a = CommandLine.arguments
    // Пять хвостовых аргументов — забыт архив: молча пропустить массовую разметку нельзя.
    guard a.count != i + 6 else {
        FileHandle.standardError.write(Data(("--smoke-voices: нужны 4 или 6 аргументов "
            + "(<speakers> <python> <worker> <база голосов> [<результаты> <архив аудио>])\n").utf8))
        exit(64)
    }
    let archive = a.count > i + 6 ? (outputs: a[i + 5], archive: a[i + 6]) : nil
    exit(VoicesSmoke.run(speakersRoot: a[i + 1], python: a[i + 2],
                         workerDir: a[i + 3], voicesDir: a[i + 4], archive: archive))
}

// Дымовая проверка MCP-сервера: MLaudApp --smoke-agents <python> <каталог worker> <порт> [hold]
if let i = CommandLine.arguments.firstIndex(of: "--smoke-agents"),
   CommandLine.arguments.count > i + 3, let port = Int(CommandLine.arguments[i + 3]) {
    let a = CommandLine.arguments
    exit(AgentAccessSmoke.run(python: a[i + 1], workerDir: a[i + 2], port: port,
                              hold: a.count > i + 4 && a[i + 4] == "hold"))
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
