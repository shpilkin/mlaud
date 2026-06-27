import Foundation

/// Хранит выбранную пользователем папку inbox (откуда забирать аудио) в UserDefaults.
public final class FolderStore {
    public static let inboxKey = "inboxFolderPath"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Папка inbox. Запись `nil` очищает значение.
    public var inboxFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Self.inboxKey), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let path = newValue?.path {
                defaults.set(path, forKey: Self.inboxKey)
            } else {
                defaults.removeObject(forKey: Self.inboxKey)
            }
        }
    }

    public var hasInboxFolder: Bool { inboxFolder != nil }
}
