import ApplicationServices
import Foundation

/// Печать текста в активное поле ввода чужого приложения.
///
/// Через синтезированные события клавиатуры с юникодной строкой, а не через
/// AX-атрибут значения: AXUIElementSetAttributeValue не работает в Electron и
/// веб-полях, а события принимает всё, что вообще принимает ввод с клавиатуры.
public struct TextInserter {
    /// macOS ограничивает юникодную строку в одном событии; бьём с запасом.
    public static let maxUnitsPerEvent = 16

    public init() {}

    /// Выдано ли разрешение «Универсальный доступ». Без него события отправляются
    /// в никуда: система их молча глотает, ошибки не будет.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показать системный запрос разрешения (если ещё не выдано).
    @discardableResult
    public static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for piece in Self.split(text) {
            var units = Array(piece.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Режем по символам, а не по UTF-16: разрыв суррогатной пары превратил бы
    /// эмодзи в два битых кода.
    public static func split(_ text: String, limit: Int = maxUnitsPerEvent) -> [String] {
        var out: [String] = []
        var current = ""
        var units = 0
        for ch in text {
            let size = String(ch).utf16.count
            if units + size > limit, !current.isEmpty {
                out.append(current)
                current = ""
                units = 0
            }
            current.append(ch)
            units += size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
