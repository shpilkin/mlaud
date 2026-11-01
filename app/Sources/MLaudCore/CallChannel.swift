import Foundation

/// Каналы звонка. Идентификаторы протокола — "me"/"them" (D4); "main" — неявная сессия
/// диктовки, для звонка запрещён.
public enum CallChannel: String, CaseIterable, Codable, Sendable {
    case me, them
    public var index: Int { self == .me ? 0 : 1 }     // 0 = левый = микрофон
    public var key: String { String(index) }          // ключ в channels.json
    public var defaultLabel: String { self == .me ? "Я" : "Собеседник" }
    public static let reservedID = "main"
}

/// FR-12.15: одна строка при старте; текст фиксирован здесь, экраны его не выдумывают.
public enum CallConsent {
    public static let line = "Участники должны знать, что звонок записывается — предупредите их."
}
