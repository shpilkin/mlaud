import Foundation

/// Машина состояний звонка: чистая, часы подставные. Недопустимые переходы игнорируются;
/// `onChange` — только когда снимок изменился.
public final class CallSession {
    public enum Input {
        case prepare(callID: String, title: String)
        case devices(input: String?, output: String?, app: String?)
        case checklist(microphone: CheckItem, appAudio: CheckItem)
        case headphones(Bool)
        case start                              // ready → running; startedAt = now
        case tick                               // elapsed = now − startedAt
        case recognizer(RecognizerStatus)
        case channel(CallChannel, ChannelHealth)
        case level(CallChannel, Float)
        case transcript(lines: [TranscriptLine], tails: [CallChannel: String])
        case recorded(TimeInterval)
        case stop                               // running → finishing
        case finalized(URL)                     // finishing → done, result
        case failed(String)                     // любая фаза → error (phase не меняется, кроме finishing → done с error)
        case dismiss                            // ready|done → idle, снимок сбрасывается в CallSnapshot()
        // Суфлёр (этап 4): ни одно событие не меняет phase — транскрипт и запись продолжаются (FR-12.16).
        case prompter(PrompterStatus)
        case prompterReady(contextTokens: Int?, warnings: [String], profileEmpty: Bool, connectionName: String?, briefTitle: String?)
        case card(PromptCard, turn: Int)        // стрим карточки до полного ответа
        case cards(turn: Int, cards: [PromptCard], agenda: [AgendaItem], questionPending: Bool,
                   usage: PrompterUsage, firstCardMs: Int?, latencyMs: Int, costTotalUSD: Double)
        case timeCard(PromptCard)               // локальная, id "t.50"|"t.80"|"t.100" — в начало cards
        case pin(String)
        case unpin(String)
        case dismissCard(String)
        case detail(cardID: String, text: String)
        case agendaManual(item: String, status: AgendaStatus)
        case note(String)
        case outcomeState(OutcomeState)
        case outcome(CallOutcome)
    }

    private let now: () -> Date
    public private(set) var snapshot = CallSnapshot()
    public var onChange: ((CallSnapshot) -> Void)?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func apply(_ input: Input) {
        var s = snapshot
        switch input {
        case .prepare(let callID, let title):
            // Из idle — новый снимок; в ready — только обновить id и заголовок (callID рождается при старте, §4.4).
            switch s.phase {
            case .idle: s = CallSnapshot(); s.phase = .ready
            case .ready: break
            default: return
            }
            s.callID = callID
            s.title = title
        case .devices(let input, let output, let app):
            s.inputDeviceName = input
            s.outputDeviceName = output
            s.appName = app
        case .checklist(let microphone, let appAudio):
            s.microphone = microphone
            s.appAudio = appAudio
        case .headphones(let warning):
            s.headphonesWarning = warning
        case .start:
            guard s.canStart else { return }
            s.phase = .running
            s.startedAt = now()
            s.elapsed = 0
            s.error = nil
        case .tick:
            guard s.phase == .running, let startedAt = s.startedAt else { return }
            s.elapsed = max(0, now().timeIntervalSince(startedAt))
        case .recognizer(let status):
            s.recognizer = status
        case .channel(let ch, let health):
            switch ch {
            case .me: s.me = health
            case .them: s.them = health
            }
        case .level(let ch, let level):
            switch ch {
            case .me: s.levels.me = level
            case .them: s.levels.them = level
            }
        case .transcript(let lines, let tails):
            s.lines = lines
            s.tails = tails
        case .recorded(let seconds):
            s.recordedSec = seconds
        case .stop:
            guard s.phase == .running else { return }
            s.phase = .finishing
            // Итоги считаются только у включённого суфлёра (§1.4).
            switch s.prompter.status {
            case .off, .disabled: break
            default: s.prompter.outcomeState = .computing
            }
        case .finalized(let url):
            guard s.phase == .finishing else { return }
            s.phase = .done
            s.result = url
        case .failed(let message):
            s.error = message
            if s.phase == .finishing { s.phase = .done }
        case .dismiss:
            guard s.phase == .ready || s.phase == .done else { return }
            s = CallSnapshot()
        case .prompter(let status):
            s.prompter.status = status
        case .prompterReady(let contextTokens, let warnings, let profileEmpty, let connectionName, let briefTitle):
            s.prompter.status = .warming
            s.prompter.briefLoaded = true
            s.prompter.contextTokens = contextTokens
            s.prompter.warnings = warnings
            s.prompter.profileEmpty = profileEmpty
            s.prompter.connectionName = connectionName
            s.prompter.briefTitle = briefTitle
        case .card(let card, let turn):
            // Первая карточка нового хода очищает прошлую порцию; "t.*" и pinned остаются (FR-12.6).
            if turn > s.prompter.lastTurn {
                s.prompter.cards = s.prompter.cards.filter { $0.id.hasPrefix("t.") }
                s.prompter.lastTurn = turn
            }
            guard !s.prompter.dismissed.contains(card.id) else { break }
            s.prompter.cards.append(card)
        case .cards(let turn, let cards, let agenda, let questionPending, let usage, let firstCardMs, let latencyMs, let costTotalUSD):
            let keepTime = s.prompter.cards.filter { $0.id.hasPrefix("t.") }
            s.prompter.cards = keepTime + cards.filter { !s.prompter.dismissed.contains($0.id) }
            s.prompter.lastTurn = turn
            // Повестка приходит изменениями: применить по item, порядок не трогать.
            for change in agenda {
                if let idx = s.prompter.agenda.firstIndex(where: { $0.item == change.item }) {
                    s.prompter.agenda[idx].status = change.status
                } else {
                    s.prompter.agenda.append(change)
                }
            }
            s.prompter.questionPending = questionPending
            s.prompter.turns += 1
            s.prompter.lastLatencyMs = latencyMs
            s.prompter.lastFirstCardMs = firstCardMs
            s.prompter.lastCachedTokens = usage.cachedTokens
            s.prompter.costUSD = costTotalUSD        // итог сессии, не приращение
        case .timeCard(let card):
            guard !s.prompter.dismissed.contains(card.id) else { break }
            s.prompter.cards.insert(card, at: 0)
        case .pin(let id):
            if let idx = s.prompter.cards.firstIndex(where: { $0.id == id }) {
                s.prompter.pinned.append(s.prompter.cards.remove(at: idx))
            }
        case .unpin(let id):
            if let idx = s.prompter.pinned.firstIndex(where: { $0.id == id }) {
                s.prompter.cards.append(s.prompter.pinned.remove(at: idx))
            }
        case .dismissCard(let id):
            s.prompter.cards.removeAll { $0.id == id }
            s.prompter.pinned.removeAll { $0.id == id }
            s.prompter.dismissed.insert(id)
        case .detail(let cardID, let text):
            s.prompter.details[cardID] = text
        case .agendaManual(let item, let status):
            if let idx = s.prompter.agenda.firstIndex(where: { $0.item == item }) {
                s.prompter.agenda[idx].status = status
            }
        case .note(let text):
            s.prompter.notes.append(text)
        case .outcomeState(let state):
            s.prompter.outcomeState = state
        case .outcome(let outcome):
            s.prompter.outcome = outcome
            s.prompter.outcomeState = .ready
        }
        guard s != snapshot else { return }
        snapshot = s
        onChange?(s)
    }
}
