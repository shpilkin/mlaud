import Foundation

/// Секреты: протокол в Core (тестируемая логика), Keychain — в App; память — для тестов и --screenshot.
public protocol SecretStore: AnyObject {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws   // nil → удалить
}

public final class InMemorySecretStore: SecretStore {
    private var secrets: [String: String] = [:]

    public init() {}

    public func secret(for account: String) -> String? {
        secrets[account]
    }

    public func setSecret(_ value: String?, for account: String) {
        if let value { secrets[account] = value } else { secrets.removeValue(forKey: account) }
    }
}
