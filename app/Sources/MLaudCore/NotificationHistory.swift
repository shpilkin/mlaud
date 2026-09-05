import Foundation

/// Одно сообщение приложения: ровно то, что показывает баннер в углу экрана.
public struct AppNotification: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let body: String
    public let date: Date
    public var isRead: Bool
    /// Куда ведёт клик по баннеру: `nil` — в журнал, `"voices"` — в окно «Голоса».
    /// Старые записи без поля читаются как `nil`.
    public let action: String?

    public init(id: UUID = UUID(), title: String, body: String,
                date: Date = Date(), isRead: Bool = false, action: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.date = date
        self.isRead = isRead
        self.action = action
    }
}

/// Журнал уведомлений.
///
/// Баннер живёт несколько секунд и не открывается: у менюбар-приложения нет окна,
/// которое система могла бы показать по клику. Текст ошибки при этом бывает длиннее
/// баннера и нужен позже, а не в момент показа. Поэтому пишем всё в журнал —
/// независимо от того, разрешены ли системные уведомления: галка в настройках
/// управляет баннером, а не тем, помнит ли приложение, о чём сообщало.
public final class NotificationHistory {
    private let url: URL
    private let limit: Int
    private let lock = NSLock()
    private var storage: [AppNotification]

    /// `limit` — сколько записей хранить; старые отбрасываются, файл не растёт вечно.
    public init(url: URL, limit: Int = 200) {
        self.url = url
        self.limit = limit
        self.storage = Self.read(from: url)
    }

    /// Записи, новые сверху.
    public var records: [AppNotification] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public var unreadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    @discardableResult
    public func append(title: String, body: String, date: Date = Date(),
                       action: String? = nil) -> AppNotification {
        let record = AppNotification(title: title, body: body, date: date, action: action)
        mutate { list in
            list.insert(record, at: 0)
            if list.count > self.limit { list.removeLast(list.count - self.limit) }
        }
        return record
    }

    public func record(id: UUID) -> AppNotification? {
        lock.lock(); defer { lock.unlock() }
        return storage.first { $0.id == id }
    }

    public func markRead(id: UUID) {
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].isRead = true
        }
    }

    public func markAllRead() {
        mutate { list in
            for index in list.indices { list[index].isRead = true }
        }
    }

    public func clear() {
        mutate { $0.removeAll() }
    }

    // MARK: - Хранение

    private func mutate(_ change: (inout [AppNotification]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&storage)
        Self.write(storage, to: url)
    }

    private static func read(from url: URL) -> [AppNotification] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Битый файл — не повод падать: журнал вспомогательный, начинаем с чистого.
        return (try? decoder.decode([AppNotification].self, from: data)) ?? []
    }

    private static func write(_ records: [AppNotification], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Даты в ISO-8601: файл иногда читают глазами.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
