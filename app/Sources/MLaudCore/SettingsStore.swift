import Foundation

/// Пользовательские настройки приложения (UserDefaults).
/// Часть из них пробрасывается в worker через окружение (см. workerEnvironment()).
public final class SettingsStore {
    public enum Key {
        public static let telegramToken = "telegramToken"
        public static let telegramChatID = "telegramChatID"
        public static let modelType = "modelType"
        public static let instantWatch = "instantWatch"
        public static let notifications = "notificationsEnabled"
        public static let diarize = "diarizeEnabled"
        public static let hfToken = "hfToken"
        public static let numSpeakers = "numSpeakers"
        public static let diarizeDevice = "diarizeDevice"
        public static let dictation = "dictationEnabled"
        public static let phoneSync = "phoneSyncEnabled"
        public static let dictationKeyCode = "dictationKeyCode"
        public static let dictationModifiers = "dictationModifiers"
        public static let identify = "identifyEnabled"
        public static let identifyPreset = "identifyPreset"
        public static let callApp = "callAppBundleID"
        public static let promptRPM = "promptRPM"
        public static let promptCostCeiling = "promptCostCeilingUSD"
        public static let materialsBudget = "materialsBudgetTokens"
        public static let compactPanelAtStart = "compactPanelAtStart"
        public static let llmConnections = "llmConnections"
        public static let llmDefault = "llmDefaultConnection"
        public static let agentAccess = "agentAccessEnabled"
        public static let agentPort = "agentAccessPort"
    }

    /// Порог узнавания голоса: три пресета из замера (ADR-016), а не сырое число.
    public enum IdentifyPreset: String, CaseIterable {
        case strict, balanced, soft

        public var threshold: Double {
            switch self {
            case .strict: return 0.80
            case .balanced: return 0.75
            case .soft: return 0.70
            }
        }

        public var title: String {
            switch self {
            case .strict: return "строго (0.80) — ни одного чужого имени"
            case .balanced: return "баланс (0.75)"
            case .soft: return "мягко (0.70) — больше имён, изредка чужое"
            }
        }
    }

    public static let defaultModel = "rnnt"
    public static let availableModels = ["rnnt", "ctc"]
    public static let defaultDevice = "mps"
    public static let availableDevices = ["mps", "cpu"]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var telegramToken: String {
        get { defaults.string(forKey: Key.telegramToken) ?? "" }
        set { defaults.set(newValue, forKey: Key.telegramToken) }
    }

    public var telegramChatID: String {
        get { defaults.string(forKey: Key.telegramChatID) ?? "" }
        set { defaults.set(newValue, forKey: Key.telegramChatID) }
    }

    public var modelType: String {
        get {
            let v = defaults.string(forKey: Key.modelType) ?? Self.defaultModel
            return Self.availableModels.contains(v) ? v : Self.defaultModel
        }
        set { defaults.set(newValue, forKey: Key.modelType) }
    }

    /// Мгновенная обработка новых файлов (FolderWatcher). По умолчанию включено.
    public var instantWatch: Bool {
        get { defaults.object(forKey: Key.instantWatch) == nil ? true : defaults.bool(forKey: Key.instantWatch) }
        set { defaults.set(newValue, forKey: Key.instantWatch) }
    }

    /// Системные уведомления о готовности/ошибке. По умолчанию включено.
    public var notificationsEnabled: Bool {
        get { defaults.object(forKey: Key.notifications) == nil ? true : defaults.bool(forKey: Key.notifications) }
        set { defaults.set(newValue, forKey: Key.notifications) }
    }

    /// Диаризация (pyannote). По умолчанию выключена. Требует hfToken.
    public var diarizeEnabled: Bool {
        get { defaults.bool(forKey: Key.diarize) }
        set { defaults.set(newValue, forKey: Key.diarize) }
    }

    public var hfToken: String {
        get { defaults.string(forKey: Key.hfToken) ?? "" }
        set { defaults.set(newValue, forKey: Key.hfToken) }
    }

    /// Число спикеров (0 = автоопределение).
    public var numSpeakers: Int {
        get { max(0, defaults.integer(forKey: Key.numSpeakers)) }
        set { defaults.set(max(0, newValue), forKey: Key.numSpeakers) }
    }

    /// Диктовка по горячей клавише (⌃⌥D). По умолчанию включено: сам хоткей ничего
    /// не делает, пока его не нажали, а разрешения спрашиваются при первом нажатии.
    /// Приём записей с iPhone по локальной сети (замена транзита через iCloud).
    public var phoneSyncEnabled: Bool {
        get { defaults.object(forKey: Key.phoneSync) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.phoneSync) }
    }

    public var dictationEnabled: Bool {
        get { defaults.object(forKey: Key.dictation) == nil ? true : defaults.bool(forKey: Key.dictation) }
        set { defaults.set(newValue, forKey: Key.dictation) }
    }

    /// Сочетание клавиш для диктовки. Хранится физическим кодом клавиши и carbon-масками
    /// модификаторов: код не зависит от раскладки, поэтому под русской раскладкой
    /// сочетание не переезжает на другую клавишу.
    public var dictationHotKey: HotKey.Combo {
        get {
            guard defaults.object(forKey: Key.dictationKeyCode) != nil else {
                return .controlOptionD
            }
            let combo = HotKey.Combo(
                keyCode: UInt32(defaults.integer(forKey: Key.dictationKeyCode)),
                modifiers: UInt32(defaults.integer(forKey: Key.dictationModifiers))
            )
            return combo.isValid ? combo : .controlOptionD
        }
        set {
            guard newValue.isValid else { return }
            defaults.set(Int(newValue.keyCode), forKey: Key.dictationKeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Key.dictationModifiers)
        }
    }

    /// Подписывать известные голоса именами (Фаза 3). Опция поверх диаризации,
    /// по умолчанию выключена.
    public var identifyEnabled: Bool {
        get { defaults.bool(forKey: Key.identify) }
        set { defaults.set(newValue, forKey: Key.identify) }
    }

    public var identifyPreset: IdentifyPreset {
        get { IdentifyPreset(rawValue: defaults.string(forKey: Key.identifyPreset) ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: Key.identifyPreset) }
    }

    /// Приложение звонка по умолчанию для Суфлёра; nil ↔ ключ отсутствует.
    public var callAppBundleID: String? {
        get { defaults.string(forKey: Key.callApp) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.callApp) } else { defaults.removeObject(forKey: Key.callApp) }
        }
    }

    /// Устройство для диаризации: 'mps' (быстро, Apple Silicon) или 'cpu'.
    public var diarizeDevice: String {
        get {
            let v = defaults.string(forKey: Key.diarizeDevice) ?? Self.defaultDevice
            return Self.availableDevices.contains(v) ? v : Self.defaultDevice
        }
        set { defaults.set(newValue, forKey: Key.diarizeDevice) }
    }

    // MARK: суфлёр (этап 4, FR-12.14/12.5; в workerEnvironment не попадают никогда)

    /// Запросов в минуту максимум.
    public var promptRPM: Int {
        get { max(1, defaults.integer(forKey: Key.promptRPM) == 0 ? 6 : defaults.integer(forKey: Key.promptRPM)) }
        set { defaults.set(max(1, newValue), forKey: Key.promptRPM) }
    }

    /// Потолок стоимости за звонок, $; nil ↔ без потолка. По умолчанию 0.50 (RESULT:108-109 —
    /// ограничивать надо задержку, а не расход); «без потолка» хранится как -1.
    public var promptCostCeilingUSD: Double? {
        get {
            guard let raw = defaults.object(forKey: Key.promptCostCeiling) else { return 0.50 }
            let v = (raw as? NSNumber)?.doubleValue ?? 0.50
            return v < 0 ? nil : v
        }
        set { defaults.set(newValue ?? -1, forKey: Key.promptCostCeiling) }
    }

    /// Бюджет материалов, токенов (FP:146-147).
    public var materialsBudgetTokens: Int {
        get { defaults.object(forKey: Key.materialsBudget) == nil ? 120_000 : max(0, defaults.integer(forKey: Key.materialsBudget)) }
        set { defaults.set(max(0, newValue), forKey: Key.materialsBudget) }
    }

    /// Компактная панель открывается автоматически при старте звонка (UX-OQ-7).
    public var compactPanelAtStart: Bool {
        get { defaults.bool(forKey: Key.compactPanelAtStart) }
        set { defaults.set(newValue, forKey: Key.compactPanelAtStart) }
    }

    /// Доступ внешних агентов по MCP (docs/mcp.md). По умолчанию выключен.
    public var agentAccessEnabled: Bool {
        get { defaults.bool(forKey: Key.agentAccess) }
        set { defaults.set(newValue, forKey: Key.agentAccess) }
    }

    /// Порт MCP на 127.0.0.1; вне 1024…65535 — порт по умолчанию.
    public var agentAccessPort: Int {
        get {
            let v = defaults.integer(forKey: Key.agentPort)
            return (1024...65535).contains(v) ? v : AgentAccess.defaultPort
        }
        set { defaults.set(newValue, forKey: Key.agentPort) }
    }

    /// Переменные окружения для worker'а. Telegram-ключи добавляются только если заданы —
    /// иначе worker возьмёт значения из своего .env (обратная совместимость).
    public func workerEnvironment() -> [String: String] {
        var env = ["MLAUD_MODEL": modelType]
        let token = telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { env["MLAUD_TG_TOKEN"] = token }
        if !chat.isEmpty { env["MLAUD_TG_CHAT_ID"] = chat }

        if diarizeEnabled {
            env["MLAUD_DIARIZE"] = "1"
            env["MLAUD_DIARIZE_DEVICE"] = diarizeDevice
            // Идентификация без диаризации невозможна: без неё нет кластеров.
            if identifyEnabled {
                env["MLAUD_IDENTIFY"] = "1"
                env["MLAUD_IDENTIFY_THRESHOLD"] = String(format: "%.2f", identifyPreset.threshold)
            }
        }
        let hf = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hf.isEmpty { env["MLAUD_HF_TOKEN"] = hf }
        if numSpeakers > 0 { env["MLAUD_NUM_SPEAKERS"] = String(numSpeakers) }
        return env
    }
}
