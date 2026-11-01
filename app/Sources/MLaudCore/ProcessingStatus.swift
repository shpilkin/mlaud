import Foundation

/// Состояние обработки для отображения в строке меню.
public enum ProcessingStatus: Equatable, Sendable {
    case idle
    case noFolder
    case processing(current: Int, total: Int)
    case done(count: Int)
    case error(String)

    /// Текст для пункта-статуса в меню.
    public var menuTitle: String {
        switch self {
        case .idle:
            return "Ожидание — слежу за папкой"
        case .noFolder:
            return "Папка не выбрана"
        case let .processing(current, total):
            return "Транскрибирую \(current) из \(total)…"
        case let .done(count):
            return "Готово: обработано \(count)"
        case let .error(message):
            return "Ошибка: \(message)"
        }
    }
}
