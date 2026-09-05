import AppKit
import Foundation
import MLaudCore
import Observation

/// Раздел главного окна. Порядок — порядок в сайдбаре и в ⌘1…⌘8.
enum AppSection: Int, CaseIterable, Identifiable {
    case overview = 1, recordings, prompter, voices, dictation, phone, notifications, settings
    /// Витрина компонентов: не в сайдбаре, открывается ⌥-кликом по «Настройки».
    case styleguide

    var id: Int { rawValue }

    /// Разделы сайдбара над разделителем; «Настройки» — под ним, витрина — скрыта.
    static let primary: [AppSection] = [.overview, .recordings, .prompter, .voices, .dictation, .phone, .notifications]
    /// Разделы с сочетанием ⌘1…⌘8.
    static let shortcuts: [AppSection] = primary + [.settings]

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .recordings: return "Записи"
        case .prompter: return "Суфлёр"
        case .voices: return "Голоса"
        case .dictation: return "Диктовка"
        case .phone: return "iPhone"
        case .notifications: return "Уведомления"
        case .settings: return "Настройки"
        case .styleguide: return "Витрина"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .recordings: return "waveform.and.magnifyingglass"
        case .prompter: return "text.bubble"
        case .voices: return "person.wave.2"
        case .dictation: return "mic"
        case .phone: return "iphone"
        case .notifications: return "bell"
        case .settings: return "gearshape"
        case .styleguide: return "paintpalette"
        }
    }
}

/// Доступ к микрофону для экрана диктовки.
enum MicrophoneStatus: Equatable {
    case notDetermined, authorized, denied
}

/// Состояние приложения для экранов: одна наблюдаемая модель, которую заполняет оболочка.
/// Экраны читают её и зовут `commands`; в обратную сторону ссылок нет.
@Observable
final class AppModel {
    var section: AppSection = .overview

    // Обзор и записи
    var overview = OverviewState()
    var recordings: [Recording] = []

    // Уведомления
    var notifications: [AppNotification] = []
    var unreadCount = 0
    /// Запись, к которой надо проскроллить: клик по системному баннеру.
    var revealNotification: UUID?

    // iPhone
    var phone: PhoneSyncController.State = .disabled
    var phoneLastReceived: PhoneSyncController.Received?
    var phoneReceipts: [PhoneReceipt] = []

    // Диктовка
    var dictation: DictationController.State = .off
    var hotKeyFailed = false
    var microphone: MicrophoneStatus = .notDetermined
    var accessibilityTrusted = false
    var dictationLog: [String] = []

    // Голоса: счётчик «к разметке» для сайдбара и обзора считает оболочка по всем сайдкарам;
    // состояние самого раздела (записи, карточки, база людей) — в `voices`.
    var voicesPending = 0
    let voices: VoicesModel

    var toast: String?

    let settings: SettingsModel
    weak var commands: AppCommands?

    init(settings: SettingsModel, voices: VoicesModel) {
        self.settings = settings
        self.voices = voices
    }

    var recordingsGrouped: [(period: String, items: [Recording])] {
        RecordingIndex.grouped(recordings)
    }

    /// Подпись справа от пункта сайдбара.
    func sidebarTrailing(for section: AppSection) -> NitiTrailing {
        switch section {
        case .overview:
            switch overview.status {
            case .noFolder: return .none
            case .idle, .done: return .dot(.success)
            case .processing: return .dot(.accent)
            case .error: return .dot(.danger)
            }
        case .voices:
            return voicesPending > 0 ? .badge(voicesPending) : .none
        case .dictation:
            guard settings.dictationEnabled else { return .text("выкл") }
            switch dictation {
            case .off: return .text(settings.dictationHotKey.display)
            case .starting: return .text("модель…")
            case .listening: return .dot(.danger)
            }
        case .phone:
            guard settings.phoneSyncEnabled else { return .none }
            switch phone {
            case .disabled: return .none
            case .starting: return .text("запуск…")
            case .listening: return .text("жду")
            case .failed: return .dot(.danger)
            }
        case .notifications:
            return unreadCount > 0 ? .badge(unreadCount) : .none
        case .recordings, .prompter, .settings, .styleguide:
            return .none
        }
    }
}

/// Хвост пункта сайдбара без привязки к цветам NitiUI: тон переводится в цвет на экране.
enum NitiTrailing: Equatable {
    enum Tone: Equatable { case accent, success, danger }
    case none
    case badge(Int)
    case text(String)
    case dot(Tone)
}
