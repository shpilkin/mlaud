import Foundation

/// Решения контроллера без процесса — как AppAudioPolicy (таблица FR-12.16 в §1.6 брифа).
public enum PrompterPolicy {
    public enum StartDecision: Equatable {
        case off
        case disabled(String)
        case start(LLMConnection)
    }

    /// Брифа нет / prompter: off → .off; модель "default" → подключение по умолчанию; имя →
    /// по имени; нет ключа у выбранного подключения → .disabled с причиной.
    public static func startDecision(brief: Brief?, connections: LLMConnectionsStore,
                                     hasKey: (String) -> Bool) -> StartDecision {
        guard let brief, brief.prompter else { return .off }
        let connection: LLMConnection
        if brief.model == "default" {
            guard let def = connections.defaultConnection else { return .disabled("нет подключений") }
            connection = def
        } else if let named = connections.connection(named: brief.model) {
            connection = named
        } else {
            return .disabled("подключение «\(brief.model)» не найдено")
        }
        guard hasKey(connection.id) else { return .disabled("нет ключа у подключения «\(connection.name)»") }
        return .start(connection)
    }

    public enum AfterCrash: Equatable { case restart(attempt: Int), giveUp }

    /// Перезапускать до maxAttempts падений за window секунд.
    public static func afterCrash(history: [Date], now: Date, maxAttempts: Int = 3,
                                  window: TimeInterval = 60) -> AfterCrash {
        let recent = history.filter { now.timeIntervalSince($0) <= window && $0 <= now }
        let attempt = recent.count + 1
        return attempt > maxAttempts ? .giveUp : .restart(attempt: attempt)
    }

    /// Таблица §1.6: событие → новый статус; nil — статус не меняется.
    public static func status(for event: PrompterEvent, current: PrompterStatus) -> PrompterStatus? {
        switch event {
        case .error(let message, let retryInSec, let fatal, _):
            if fatal { return .disabled(message) }
            return .retrying(message: message, inSec: retryInSec ?? 10)
        case .waiting(let reason, let sec):
            return .waiting(reason: reason, sec: sec)
        case .paused(_, let cost, let ceiling):
            return .pausedByCost(costUSD: cost, ceilingUSD: ceiling)
        case .cards:
            return .ready        // снимает retrying/waiting (§1.6)
        case .card:
            return nil           // стрим внутри хода — статус не меняет
        case .warm(let ok, _, _):
            return ok ? .ready : nil
        default:
            return nil
        }
    }

    /// Новые строки с прошлого отправленного хода: id > lastSentID (nil → все).
    public static func linesSince(_ lines: [TranscriptLine], lastSentID: Int?) -> [TranscriptLine] {
        guard let lastSentID else { return lines }
        return lines.filter { $0.id > lastSentID }
    }
}
