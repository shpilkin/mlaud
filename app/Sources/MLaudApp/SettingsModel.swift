import Foundation
import MLaudCore
import Observation

/// Настройки для экранов: наблюдаемая копия `SettingsStore`, запись — сразу при изменении
/// (macOS-конвенция, без кнопки «Сохранить»), побочный эффект — по ключу, а не «перезапустить
/// всё»: смена Telegram-токена не должна перезагружать резидентную модель диктовки.
@Observable
final class SettingsModel {
    /// Что нужно пересобрать после изменения ключа.
    enum Change {
        case watcher, dictation, phoneSync, voices, notifications
    }

    enum TelegramTest: Equatable {
        case idle, running, ok, failed(String)
    }

    private let store: SettingsStore
    var onChange: (Change) -> Void = { _ in }

    var telegramToken: String { didSet { store.telegramToken = telegramToken } }
    var telegramChatID: String { didSet { store.telegramChatID = telegramChatID } }
    var modelType: String { didSet { store.modelType = modelType } }
    var instantWatch: Bool { didSet { store.instantWatch = instantWatch; onChange(.watcher) } }
    var notificationsEnabled: Bool {
        didSet { store.notificationsEnabled = notificationsEnabled; onChange(.notifications) }
    }
    var diarizeEnabled: Bool { didSet { store.diarizeEnabled = diarizeEnabled; onChange(.voices) } }
    var hfToken: String { didSet { store.hfToken = hfToken } }
    var numSpeakers: Int { didSet { store.numSpeakers = numSpeakers } }
    var diarizeDevice: String { didSet { store.diarizeDevice = diarizeDevice } }
    var dictationEnabled: Bool { didSet { store.dictationEnabled = dictationEnabled; onChange(.dictation) } }
    /// Только годное сочетание: рекордер сам отсеивает нажатия без модификатора.
    var dictationHotKey: HotKey.Combo {
        didSet {
            guard dictationHotKey.isValid, dictationHotKey != oldValue else { return }
            store.dictationHotKey = dictationHotKey
            onChange(.dictation)
        }
    }
    var phoneSyncEnabled: Bool { didSet { store.phoneSyncEnabled = phoneSyncEnabled; onChange(.phoneSync) } }
    var identifyEnabled: Bool { didSet { store.identifyEnabled = identifyEnabled; onChange(.voices) } }
    var identifyPreset: SettingsStore.IdentifyPreset { didSet { store.identifyPreset = identifyPreset } }

    /// Автозапуск живёт в системе (`SMAppService`), не в store: читается при показе экрана.
    private(set) var loginItemEnabled = false
    private(set) var loginError: String?
    var telegramTest: TelegramTest = .idle

    init(store: SettingsStore) {
        self.store = store
        telegramToken = store.telegramToken
        telegramChatID = store.telegramChatID
        modelType = store.modelType
        instantWatch = store.instantWatch
        notificationsEnabled = store.notificationsEnabled
        diarizeEnabled = store.diarizeEnabled
        hfToken = store.hfToken
        numSpeakers = store.numSpeakers
        diarizeDevice = store.diarizeDevice
        dictationEnabled = store.dictationEnabled
        dictationHotKey = store.dictationHotKey
        phoneSyncEnabled = store.phoneSyncEnabled
        identifyEnabled = store.identifyEnabled
        identifyPreset = store.identifyPreset
    }

    /// Диаризация включена, а токена HF нет — файлы пойдут без меток спикеров.
    var diarizeWithoutToken: Bool {
        diarizeEnabled && hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = "\(error.localizedDescription). Автозапуск работает только у приложения, установленного в /Applications."
        }
        loginItemEnabled = LoginItem.isEnabled
    }
}
