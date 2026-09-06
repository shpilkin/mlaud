import Foundation
import MLaudCore
import Security

/// Ключи подключений модели в Keychain (FR-12.13, ADR-022): account = id подключения.
/// Ad-hoc подпись (swift run, --screenshot) даёт системный запрос доступа после пересборки;
/// установленная сборка подписана стабильно (build-dmg.sh) — принято, записано в README.
final class KeychainStore: SecretStore {
    private let service: String

    init(service: String = "com.mlaud.app.llm") {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func secret(for account: String) -> String? {
        var item = query(for: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Есть ли запись вообще (поиск по атрибутам, без чтения секрета): отличает
    /// «ключа нет» от «ключ есть, но Keychain не отдаёт его этому процессу».
    func contains(_ account: String) -> Bool {
        var item = query(for: account)
        item[kSecReturnAttributes as String] = true
        var result: AnyObject?
        return SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess
    }

    func setSecret(_ value: String?, for account: String) throws {
        guard let value else {
            let status = SecItemDelete(query(for: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(for: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(for: account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
