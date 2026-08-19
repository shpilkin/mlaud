import Carbon.HIToolbox
import Foundation

/// Системная горячая клавиша поверх любого приложения.
///
/// Carbon `RegisterEventHotKey`, а не `NSEvent.addGlobalMonitorForEvents`, потому что
/// глобальный монитор NSEvent требует разрешения «Универсальный доступ» и молча ничего
/// не ловит, пока его не дали. Carbon-хоткей работает сразу и никаких разрешений не просит.
public final class HotKey {
    public struct Combo: Equatable {
        public let keyCode: UInt32
        public let modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⌃⌥D — «диктовка» по умолчанию. Не занято ни системой, ни распространёнными
        /// приложениями (⌘D — дублирование, ⌃⌘D — словарь, ⌥⌘D — скрыть Dock).
        public static let controlOptionD = Combo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey)
        )

        /// Хотя бы один модификатор обязателен: голая буква перехватывала бы ввод везде.
        public var isValid: Bool {
            modifiers & UInt32(controlKey | optionKey | cmdKey | shiftKey) != 0
                || KeyNames.isFunctionKey(keyCode)
        }

        /// Человекочитаемая запись, в порядке, принятом в macOS: ⌃⌥⇧⌘Клавиша.
        public var display: String {
            var out = ""
            if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
            if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
            if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
            if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
            return out + KeyNames.name(for: keyCode)
        }

        /// Перевод модификаторов из мира Cocoa (NSEvent) в мир Carbon (RegisterEventHotKey).
        /// Это разные наборы битов, и перепутать их — значит зарегистрировать не ту комбинацию.
        public static func carbonModifiers(fromCocoa flags: UInt) -> UInt32 {
            var out: UInt32 = 0
            if flags & (1 << 18) != 0 { out |= UInt32(controlKey) }   // .control
            if flags & (1 << 19) != 0 { out |= UInt32(optionKey) }    // .option
            if flags & (1 << 17) != 0 { out |= UInt32(shiftKey) }     // .shift
            if flags & (1 << 20) != 0 { out |= UInt32(cmdKey) }       // .command
            return out
        }
    }

    private let combo: Combo
    private let onPress: () -> Void
    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    public init(combo: Combo = .controlOptionD, onPress: @escaping () -> Void) {
        self.combo = combo
        self.onPress = onPress
    }

    /// Зарегистрировать. false — комбинация уже занята другим приложением.
    @discardableResult
    public func start() -> Bool {
        stop()
        HotKeyRegistry.shared.installHandlerOnce()
        id = HotKeyRegistry.shared.register(onPress)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4C4144), id: id)  // 'MLAD'
        var out: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &out
        )
        guard status == noErr, let out else {
            HotKeyRegistry.shared.unregister(id)
            id = 0
            return false
        }
        ref = out
        return true
    }

    public func stop() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        if id != 0 {
            HotKeyRegistry.shared.unregister(id)
            id = 0
        }
    }

    public var isRegistered: Bool { ref != nil }

    deinit { stop() }
}

/// Carbon отдаёт события в C-функцию без контекста, поэтому обработчики живут
/// в общем реестре и ищутся по id хоткея.
final class HotKeyRegistry {
    static let shared = HotKeyRegistry()

    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private let lock = NSLock()

    func register(_ handler: @escaping () -> Void) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = nil
    }

    func fire(_ id: UInt32) {
        lock.lock()
        let handler = handlers[id]
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async(execute: handler)
    }

    func installHandlerOnce() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if status == noErr {
                HotKeyRegistry.shared.fire(hotKeyID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Подписи физических клавиш. Именно физических: под русской раскладкой клавиша D
/// печатает «в», но в сочетаниях macOS показывает букву гравировки — так же делаем и мы.
public enum KeyNames {
    private static let table: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "\u{21A9}",
        UInt32(kVK_Tab): "\u{21E5}", UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Delete): "\u{232B}", UInt32(kVK_ForwardDelete): "\u{2326}",
        UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}",
        UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "PgUp", UInt32(kVK_PageDown): "PgDn",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    public static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "код \(keyCode)"
    }

    /// Функциональные клавиши годятся как хоткей и без модификаторов.
    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        let fkeys: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
            UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        ]
        return fkeys.contains(keyCode)
    }
}
