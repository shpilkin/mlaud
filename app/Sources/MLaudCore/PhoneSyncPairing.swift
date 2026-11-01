import Foundation
import Security

/// Секрет сопряжения с телефоном.
///
/// Лежит файлом в `~/ASR/service/sync/pairing.json` с правами 0600, а не в Keychain,
/// и это осознанно: приложение поставляется **неподписанным** (ADR-008), подпись
/// ad-hoc меняется на каждой сборке, а ACL элемента Keychain привязан к подписи —
/// пользователь получал бы запрос доступа после каждого обновления. Файл в домашней
/// папке под 0600 даёт ту же защиту от чужого пользователя и не мешает жить.
public struct PhoneSyncPairing: Codable, Equatable, Sendable {
    public let serverID: UUID
    /// 16 байт: 128 бит достаточно — секрет передаётся визуально (QR) и не подбирается
    /// онлайн, неверный PSK роняет TLS-хендшейк.
    public let psk: Data
    public var createdAt: Date

    public init(serverID: UUID = UUID(), psk: Data, createdAt: Date = Date()) {
        self.serverID = serverID
        self.psk = psk
        self.createdAt = createdAt
    }

    public static let pskByteCount = 16
}

public final class PhoneSyncPairingStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Существующее сопряжение или новое, созданное прямо сейчас.
    public func loadOrCreate() throws -> PhoneSyncPairing {
        if let existing = load() { return existing }
        let pairing = PhoneSyncPairing(psk: Self.randomSecret())
        try save(pairing)
        return pairing
    }

    public func load() -> PhoneSyncPairing? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneSyncPairing.self, from: data)
    }

    /// Новый секрет: все ранее сопряжённые телефоны придётся связать заново.
    @discardableResult
    public func regenerate() throws -> PhoneSyncPairing {
        let pairing = PhoneSyncPairing(psk: Self.randomSecret())
        try save(pairing)
        return pairing
    }

    public func save(_ pairing: PhoneSyncPairing) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(pairing)
        try data.write(to: url, options: .atomic)
        // Права выставляем после записи: `write(options: .atomic)` создаёт новый файл
        // и права предыдущего не наследует.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    static func randomSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: PhoneSyncPairing.pskByteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
