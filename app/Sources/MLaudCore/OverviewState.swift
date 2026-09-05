import Foundation

/// Русские формы множественного числа: «1 файл, 2 файла, 5 файлов».
public enum RussianPlural {
    public static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }
}

/// Состояние экрана «Обзор» — всё, что экран показывает, без ссылок на контроллеры.
/// Заполняется приложением из тех же источников, что раньше кормили меню; здесь — правила
/// показа, которые проверяются без UI.
public struct OverviewState: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral, accent, success, warning, danger, muted
    }

    public var status: ProcessingStatus = .noFolder
    public var inboxPath: String?
    /// Готовые к обработке файлы в inbox.
    public var ready = 0
    /// Файлы iCloud, которые ещё докачиваются (dataless / `.icloud`).
    public var downloading = 0
    /// Транскрипты, ждущие отправки в Telegram после сбоя сети.
    public var pendingDelivery = 0
    /// Карантин упавших файлов (`~/ASR/Failed`).
    public var quarantine: [URL] = []
    /// Последние обработанные записи (не больше `recentLimit`).
    public var recent: [Recording] = []
    /// Последняя строка `worker.log` при ошибке — чтобы не открывать лог ради одной строки.
    public var lastLogLine: String?

    public static let recentLimit = 5

    public init() {}

    public var hasFolder: Bool { inboxPath != nil }

    public var isProcessing: Bool {
        if case .processing = status { return true }
        return false
    }

    /// «Обработать сейчас»: как в меню — есть папка и ничего не идёт. Пустая очередь не
    /// повод прятать кнопку: прогон-досыл очереди доставки тоже запускается ею.
    public var canProcessNow: Bool { hasFolder && !isProcessing }

    /// Плашка состояния конвейера: текст и тон. Текст — тот же, что в строке меню.
    public var pipeline: (text: String, tone: Tone) {
        switch status {
        case .noFolder: return (status.menuTitle, .muted)
        case .idle: return (status.menuTitle, .neutral)
        case .processing: return (status.menuTitle, .accent)
        case .done: return (status.menuTitle, .success)
        case .error: return (status.menuTitle, .danger)
        }
    }

    /// Строки блока «В очереди».
    public var queueLines: [String] {
        var lines: [String] = []
        if ready > 0 {
            lines.append("\(ready) \(RussianPlural.form(ready, "файл ждёт", "файла ждут", "файлов ждут")) обработки")
        }
        if downloading > 0 {
            lines.append("\(downloading) \(RussianPlural.form(downloading, "докачивается", "докачиваются", "докачиваются")) из iCloud")
        }
        return lines
    }

    /// Строка блока «Доставка»; nil — блок не показывается.
    public var deliveryLine: String? {
        guard pendingDelivery > 0 else { return nil }
        return "\(pendingDelivery) \(RussianPlural.form(pendingDelivery, "файл ждёт", "файла ждут", "файлов ждут")) отправки в Telegram"
    }
}
