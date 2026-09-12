import AppKit
import Foundation
import MLaudCore

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
    // Суфлёр
    func startCallSetup()
    func startCall()
    func stopCall()
    func dismissCall()
    func refreshCallApps()
    func selectCallApp(_ pid: Int32?)
    func openScreenRecordingSettings()
    func relaunchApp()
    func openCallFolder(_ callID: String)
    // Суфлёр — этап 4 (§1.7): брифы, звонок с суфлёром, карточки, итоги, подключения
    func newBrief(template: String)
    func openBrief(slug: String)
    func saveBrief(_ brief: Brief)
    func duplicateBrief(slug: String)
    func deleteBrief(slug: String)
    func openBriefFolder(slug: String)
    func addMaterials(slug: String, urls: [URL])
    func addMaterialFromRecordings(slug: String, base: String)
    func removeMaterial(slug: String, name: String)
    func startCall(brief slug: String)
    func prepareCallBrief(_ slug: String?)
    func recordSelfVoice()
    func cancelSelfVoiceRecording()
    func requestHint()
    func relabelTranscriptLine(id: Int)
    func markLastTranscriptLineThem()
    func togglePrompterPause()
    func pinCard(_ id: String)
    func unpinCard(_ id: String)
    func dismissCard(_ id: String)
    func requestDetail(_ id: String)
    func copyCard(_ id: String)
    func setAgenda(item: String, status: AgendaStatus)
    func addNote(_ text: String)
    func cancelOutcome()
    func openOutcome(callID: String)
    func saveOutcome(callID: String, markdown: String)
    func sendOutcomeToTelegram(callID: String)
    func copyOutcome(callID: String)
    func toggleCompactPanel()
    func saveProfile(_ text: String)
    func saveConnection(_ c: LLMConnection, key: String?)
    func removeConnection(id: String)
    func setDefaultConnection(id: String)
    func checkConnection(id: String)
}

/// Код связи с телефоном: QR и строка для ручного ввода.
struct PairingInfo {
    let qr: NSImage?
    let manualCode: String
}
