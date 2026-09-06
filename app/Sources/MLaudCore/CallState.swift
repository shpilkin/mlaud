import Foundation

/// Данные экрана звонка; машина состояний — `CallSession`.
public enum CallPhase: String, Equatable, Sendable { case idle, ready, running, finishing, done }

public enum CheckItem: Equatable, Sendable {
    case unknown, checking, ok
    case denied(String)         // текст подсказки
    case needsRestart           // SCK −3801: согласие дано, нужен перезапуск (poc/appaudio/RESULT.md:78)
    case unavailable(String)    // нет кандидатов / приложение вышло
}

public enum RecognizerStatus: Equatable, Sendable {
    case off, loading, ready
    case restarting(attempt: Int)
    case failed(String)
}

public enum ChannelHealth: Equatable, Sendable {
    case idle                        // до старта
    case flowing
    case silent(since: TimeInterval) // буферы идут, RMS ниже порога дольше 10 с
    case noAudio(String)             // FR-12.16: «Собеседник: нет звука» + причина
    case failed(String)
}

public struct TranscriptLine: Equatable, Sendable, Identifiable {
    public let id: Int          // монотонный id LiveTranscript; (ch, phrase) не уникальны после перезапуска распознавателя
    public let ch: CallChannel
    public let label: String
    public let t0: Double       // секунды от старта звонка
    public let t1: Double
    public let text: String

    public init(id: Int, ch: CallChannel, label: String, t0: Double, t1: Double, text: String) {
        self.id = id
        self.ch = ch
        self.label = label
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}

public struct CallLevels: Equatable, Sendable {
    public var me: Float = 0     // RMS 0…1 последнего куска
    public var them: Float = 0
    public init() {}
}

/// FR-12.16 одной таблицей (feature-prompter.md §6). Экран рисует по этому перечислению,
/// контроллер его ставит; ни одно значение не меняет phase — транскрипт и запись живут.
public enum PrompterStatus: Equatable, Sendable {
    case off                                 // prompter: off в брифе или брифа нет
    case disabled(String)                    // нет ключа / подключения / fatal-ошибка модели
    case starting                            // процесс запущен, ready не пришёл
    case warming                             // ready пришёл, прогрев идёт
    case ready                               // ждёт триггера
    case requesting(turn: Int)               // ход в полёте
    case waiting(reason: String, sec: Int)   // rpm
    case retrying(message: String, inSec: Int)   // сеть/5xx: «повтор через N с»
    case pausedByUser
    case pausedByCost(costUSD: Double, ceilingUSD: Double)
    case crashed(attempt: Int)               // процесс умер; перезапуск attempt из 3
    case failed(String)                      // перезапуски исчерпаны
}

public enum OutcomeState: Equatable, Sendable { case none, computing, ready, cancelled, failed(String) }

/// Состояние суфлёра в снимке звонка; экран звонка и компактная панель читают только его.
public struct PrompterSnapshot: Equatable, Sendable {
    public var status: PrompterStatus = .off
    public var connectionName: String? = nil
    public var briefTitle: String? = nil
    public var briefLoaded = false
    public var profileEmpty = false
    public var contextTokens: Int? = nil
    public var warnings: [String] = []
    public var cards: [PromptCard] = []            // текущая порция + локальные time-карточки; порядок = приоритет
    public var pinned: [PromptCard] = []           // закреплённые, сверху (FR-12.6)
    public var dismissed: Set<String> = []         // id убранных: повторно не показывать
    public var details: [String: String] = [:]     // id → detail по клику
    public var agenda: [AgendaItem] = []
    public var questionPending = false
    public var turns = 0
    public var lastTurn = 0                        // ход последней пришедшей порции/карточки
    public var lastLatencyMs: Int? = nil
    public var lastFirstCardMs: Int? = nil
    public var lastCachedTokens: Int? = nil
    public var costUSD: Double = 0
    public var notes: [String] = []
    public var outcome: CallOutcome? = nil
    public var outcomeState: OutcomeState = .none
    public init() {}
}

public struct CallSnapshot: Equatable, Sendable {
    public var phase: CallPhase = .idle
    public var callID: String? = nil
    public var title: String = "Звонок"          // D7: без брифа
    public var startedAt: Date? = nil
    public var elapsed: TimeInterval = 0
    public var appName: String? = nil
    public var inputDeviceName: String? = nil
    public var outputDeviceName: String? = nil
    public var headphonesWarning = false          // FR-12.1
    public var microphone: CheckItem = .unknown
    public var appAudio: CheckItem = .unknown
    public var recognizer: RecognizerStatus = .off
    public var me: ChannelHealth = .idle
    public var them: ChannelHealth = .idle
    public var levels = CallLevels()
    public var lines: [TranscriptLine] = []
    public var tails: [CallChannel: String] = [:]  // текущая фраза: коммиты + preview
    public var recordedSec: TimeInterval = 0
    public var result: URL? = nil                  // .m4a в inbox после finishing
    public var error: String? = nil
    public var mode = "vks"                         // vks | offline — из брифа (FR-12.11)
    public var prompter = PrompterSnapshot()       // последним полем: значение по умолчанию сохраняет равенство CallSnapshot() в старых тестах
    public init() {}
    public var canStart: Bool { phase == .ready && microphone == .ok }   // звук приложения может отсутствовать (FR-12.16)
}

/// Приложение-кандидат на захват звука (ScreenCaptureKit видит только процессы с окнами, D17).
public struct CallAppCandidate: Identifiable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let bundleID: String
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, bundleID: String) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
    }
}


/// Этап 5: куда положить фразу одного микрофона по живой пометке голоса (S4).
/// Свои → канал «Я»; чужие → канал «не я» (без имён); короче 2 с сигнала нет — «?».
public enum OfflineVoicePolicy {
    public static func route(_ phrase: ChannelPhrase) -> (ch: CallChannel, label: String) {
        guard let voice = phrase.voice else { return (.me, "?") }
        return voice.isSelf ? (.me, "Я") : (.them, "не я")
    }
}
