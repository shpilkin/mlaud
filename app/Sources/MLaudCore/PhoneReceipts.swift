import Foundation

/// Запись журнала приёма с iPhone (`service/sync/received.json`, пишет `SyncServer`).
public struct PhoneReceipt: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let receivedAt: Date
    public let size: Int64
    public let deviceID: String?

    public init(id: String, name: String, receivedAt: Date, size: Int64, deviceID: String? = nil) {
        self.id = id
        self.name = name
        self.receivedAt = receivedAt
        self.size = size
        self.deviceID = deviceID
    }
}

public enum PhoneReceipts {
    /// Новые сверху. Файл — словарь по id, как его пишет `SyncServer`; битый или отсутствующий
    /// файл — пустой список: журнал вспомогательный.
    public static func load(_ url: URL) -> [PhoneReceipt] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [PhoneReceipt] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "не ISO-8601: \(text)"))
        }
        guard let dict = try? decoder.decode([String: PhoneReceipt].self, from: data) else { return [] }
        return dict.values.sorted { $0.receivedAt == $1.receivedAt ? $0.name > $1.name : $0.receivedAt > $1.receivedAt }
    }

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
