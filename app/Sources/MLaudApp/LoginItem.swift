import Foundation
import ServiceManagement
import UserNotifications

/// Автозапуск при входе в систему через SMAppService (macOS 13+).
/// Работает только для установленного .app-бандла; при `swift run` register() бросит ошибку.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Включить/выключить автозапуск. Бросает, если система отказала (например, не бандл).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Системные уведомления (Центр уведомлений). Требуют бандла с идентификатором —
/// при запуске через `swift run` (без бандла) тихо ничего не делают.
enum UserNotifier {
    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Делегат нужен ради клика по баннеру: без него система просто активирует
    /// приложение, а у менюбар-приложения активация ничего не показывает.
    static func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// `identifier` — id записи в журнале: по нему клик по баннеру находит, что открыть.
    static func notify(title: String, body: String, identifier: String = UUID().uuidString) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
