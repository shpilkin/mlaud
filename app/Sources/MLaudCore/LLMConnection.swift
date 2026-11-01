import Foundation

/// Подключение модели = шлюз + модель + рассуждения (FR-12.13, ADR-022). Ключ — не здесь:
/// только Keychain по `id` (SecretStore), в сериализации ключа нет.
public struct LLMConnection: Equatable, Sendable, Identifiable, Codable {
    public enum Reasoning: Equatable, Hashable, Sendable, Codable {
        case off                    // {"enabled": false}
        case effort(String)         // {"effort": "low"} — где выключить нельзя
        case unspecified            // ключ не отправляется
    }

    public struct Price: Equatable, Sendable, Codable {
        public var input: Double?
        public var output: Double?
        public var cached: Double?
        public init(input: Double? = nil, output: Double? = nil, cached: Double? = nil) {
            self.input = input
            self.output = output
            self.cached = cached
        }
    }

    public let id: String                 // UUID-строка; account в Keychain
    public var name: String               // ADR-022: показывается на экране звонка
    public var baseURL: String
    public var model: String
    public var reasoning: Reasoning
    public var price: Price

    public init(id: String = UUID().uuidString, name: String, baseURL: String, model: String,
                reasoning: Reasoning, price: Price = .init()) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.reasoning = reasoning
        self.price = price
    }

    /// Пресеты FR-12.13 без ключа и без цен (цен в сессии не получить; стоимость — из usage.cost OpenRouter).
    public static let presets: [LLMConnection] = [
        LLMConnection(name: "DeepSeek V4 Flash (OpenRouter)",
                      baseURL: "https://openrouter.ai/api/v1",
                      model: "deepseek/deepseek-v4-flash",
                      reasoning: .off),
        LLMConnection(name: "GLM-5.3 Flash (OpenRouter)",
                      baseURL: "https://openrouter.ai/api/v1",
                      model: "z-ai/glm-5.3-flash",
                      reasoning: .effort("low")),
    ]

    /// Форма для start.connection (§2.2). Ключа здесь нет и быть не может.
    public struct Wire: Equatable, Sendable {
        public let baseURL: String
        public let model: String
        public let reasoning: Reasoning
        public let price: Price
        public init(baseURL: String, model: String, reasoning: Reasoning, price: Price) {
            self.baseURL = baseURL
            self.model = model
            self.reasoning = reasoning
            self.price = price
        }
    }

    public var wire: Wire {
        Wire(baseURL: baseURL, model: model, reasoning: reasoning, price: price)
    }
}

/// Список подключений в UserDefaults (JSON), ключ — отдельно (SecretStore).
/// Класс: контроллеры держат один экземпляр на всё приложение (§4.5).
public final class LLMConnectionsStore {
    public static let storageKey = "llmConnections"
    public static let defaultKey = "llmDefaultConnection"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func readAll() -> [LLMConnection] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let list = try? JSONDecoder().decode([LLMConnection].self, from: data)
        else { return [] }
        return list
    }

    private func writeAll(_ list: [LLMConnection]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Пусто → пресеты сеются при первом чтении и сохраняются (FR-12.13).
    public var all: [LLMConnection] {
        let list = readAll()
        guard list.isEmpty else { return list }
        writeAll(LLMConnection.presets)
        return LLMConnection.presets
    }

    public var defaultID: String? {
        get { defaults.string(forKey: Self.defaultKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.defaultKey) }
            else { defaults.removeObject(forKey: Self.defaultKey) }
        }
    }

    /// nil в хранилище → первое из списка.
    public var defaultConnection: LLMConnection? {
        let list = all
        guard !list.isEmpty else { return nil }
        if let id = defaultID, let found = list.first(where: { $0.id == id }) { return found }
        return list.first
    }

    public func save(_ connection: LLMConnection) {
        var list = readAll()
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        writeAll(list)
    }

    public func remove(id: String) {
        writeAll(readAll().filter { $0.id != id })
        if defaultID == id { defaultID = nil }
    }

    /// Для brief.model: подключение по имени.
    public func connection(named name: String) -> LLMConnection? {
        all.first { $0.name == name }
    }
}
