import AppKit
import Foundation

/// Действия экранов, которые выполняет оболочка (`AppDelegate`): процессы, окна, файлы.
/// Экраны знают только состояние (`AppModel`) и эти команды — не контроллеры.
protocol AppCommands: AnyObject {
    // Обзор
    func chooseFolder()
    func processNow()
    func openWorkerLogFile()
    func openResultsFolder()
    func retryQuarantine(_ url: URL)
    func revealInFinder(_ url: URL)
    func open(_ url: URL)
    func reloadRecordings()
    // Диктовка
    func toggleDictation()
    func requestMicrophone()
    func openAccessibilitySettings()
    func openDictationLog()
    // Уведомления
    func markNotificationRead(_ id: UUID)
    func markAllNotificationsRead()
    func clearNotifications()
    // iPhone
    func pairing() -> PairingInfo?
    func regeneratePairing()
    // Настройки
    func testTelegram()
    func showStyleguide()
}

/// Код связи с телефоном: QR и строка для ручного ввода.
struct PairingInfo {
    let qr: NSImage?
    let manualCode: String
}
