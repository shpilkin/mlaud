import Foundation

/// Тип карточки подсказки (feature-prompter.md §7.3).
public enum CardType: String, CaseIterable, Codable, Sendable {
    case answer, ask, fact, nextStep = "next_step", offRoute = "off_route", tension, time
}

public struct PromptCard: Equatable, Sendable, Identifiable {
    public let id: String          // "<turn>.<index>" от Python; "t.50"/"t.80"/"t.100" — локальные time-карточки AgendaTimer
    public let type: CardType
    public let priority: Int
    public let text: String
    public let source: String
    public init(id: String, type: CardType, priority: Int, text: String, source: String = "") {
        self.id = id
        self.type = type
        self.priority = priority
        self.text = text
        self.source = source
    }
}

public enum AgendaStatus: String, Codable, Sendable { case pending, active, done }

public struct AgendaItem: Equatable, Sendable {
    public let item: String
    public var status: AgendaStatus
    public init(item: String, status: AgendaStatus) {
        self.item = item
        self.status = status
    }
}

public struct PrompterUsage: Equatable, Sendable {
    public var promptTokens = 0
    public var completionTokens = 0
    public var cachedTokens = 0
    public var reasoningTokens = 0
    public init() {}
}

public enum GoalResult: String, Codable, Sendable { case achieved, partial, not }

public struct OutcomeAssessment: Equatable, Sendable {
    public let criterion: String
    public let verdict: String
    public let evidence: String
    public init(criterion: String, verdict: String, evidence: String) {
        self.criterion = criterion
        self.verdict = verdict
        self.evidence = evidence
    }
}

public struct CallOutcome: Equatable, Sendable {
    public var goalResult: GoalResult
    public var reason: String
    public var summary: String
    public var decisions: [String]
    public var nextSteps: [String]
    public var openQuestions: [String]
    public var assessment: [OutcomeAssessment]
    public var markdown: String        // содержимое outcome.md (Python отрендерил; Swift правит)
    public init(goalResult: GoalResult, reason: String, summary: String, decisions: [String] = [],
                nextSteps: [String] = [], openQuestions: [String] = [], assessment: [OutcomeAssessment] = [],
                markdown: String = "") {
        self.goalResult = goalResult
        self.reason = reason
        self.summary = summary
        self.decisions = decisions
        self.nextSteps = nextSteps
        self.openQuestions = openQuestions
        self.assessment = assessment
        self.markdown = markdown
    }

    /// Общий разбор outcome-объекта: событие outcome и outcome.json пишут один формат (§2.3, §3.6).
    public init?(json obj: [String: Any]) {
        guard let goal = (obj["goal_result"] as? String).flatMap(GoalResult.init(rawValue:)) else { return nil }
        let assessment = (obj["assessment"] as? [[String: Any]] ?? []).map {
            OutcomeAssessment(criterion: $0["criterion"] as? String ?? "",
                              verdict: $0["verdict"] as? String ?? "",
                              evidence: $0["evidence"] as? String ?? "")
        }
        self.init(goalResult: goal,
                  reason: obj["reason"] as? String ?? "",
                  summary: obj["summary"] as? String ?? "",
                  decisions: obj["decisions"] as? [String] ?? [],
                  nextSteps: obj["next_steps"] as? [String] ?? [],
                  openQuestions: obj["open_questions"] as? [String] ?? [],
                  assessment: assessment)
    }
}

/// Материал брифа из отчёта `--materials` (§2.4).
public struct MaterialInfo: Equatable, Sendable {
    public let name: String
    public let kind: String
    public let tokens: Int
    public let warning: String?
    public init(name: String, kind: String, tokens: Int, warning: String? = nil) {
        self.name = name
        self.kind = kind
        self.tokens = tokens
        self.warning = warning
    }
}

/// Команды → stdin процесса. Строки через JSONText — тесты сравнивают байты (§2.2).
public enum PrompterCommand: Equatable {
    public enum TurnReason: String { case themPhrase = "them_phrase", manual, timer }

    public struct Limits: Equatable, Sendable {
        public var rpm = 6
        public var costCeilingUSD: Double?
        public var debounceSec = 2.5
        public var warmEverySec = 240.0
        public init(rpm: Int = 6, costCeilingUSD: Double? = nil, debounceSec: Double = 2.5, warmEverySec: Double = 240.0) {
            self.rpm = rpm
            self.costCeilingUSD = costCeilingUSD
            self.debounceSec = debounceSec
            self.warmEverySec = warmEverySec
        }
    }

    case start(callDir: String, briefDir: String, profile: String, templatesDir: String,
               mode: String, expectedMin: Int, connection: LLMConnection.Wire, limits: Limits)
    case turn(reason: TurnReason, elapsedSec: Int, lines: [TranscriptLine], agendaManual: [AgendaItem], notes: String)
    case pause(Bool)
    case detail(cardID: String)
    case finish(elapsedSec: Int, notes: String)
    case quit

    public func line() -> String {
        switch self {
        case .start(let callDir, let briefDir, let profile, let templatesDir, let mode, let expectedMin,
                    let connection, let limits):
            // reasoning → "reasoning":{…}, с запятой; .unspecified → ключа нет вовсе (§2.2)
            var reasoning = ""
            if case .off = connection.reasoning { reasoning = "\"reasoning\":{\"enabled\":false}," }
            if case .effort(let e) = connection.reasoning { reasoning = "\"reasoning\":{\"effort\":\(JSONText.quoted(e))}," }
            return #"{"t":"start","call_dir":\#(JSONText.quoted(callDir)),"brief_dir":\#(JSONText.quoted(briefDir)),"profile":\#(JSONText.quoted(profile)),"templates_dir":\#(JSONText.quoted(templatesDir)),"mode":\#(JSONText.quoted(mode)),"expected_min":\#(expectedMin),"connection":{"base_url":\#(JSONText.quoted(connection.baseURL)),"model":\#(JSONText.quoted(connection.model)),\#(reasoning)"price_per_mtok":{"in":\#(connection.price.input.map(JSONText.number) ?? "null"),"out":\#(connection.price.output.map(JSONText.number) ?? "null"),"cached":\#(connection.price.cached.map(JSONText.number) ?? "null")}},"limits":{"rpm":\#(limits.rpm),"cost_ceiling_usd":\#(limits.costCeilingUSD.map(JSONText.number) ?? "null"),"debounce_sec":\#(JSONText.number(limits.debounceSec)),"warm_every_sec":\#(JSONText.number(limits.warmEverySec))}}"#
        case .turn(let reason, let elapsedSec, let lines, let agendaManual, let notes):
            let linesText = lines.map { line in
                #"{"ch":"\#(line.ch.rawValue)","label":\#(JSONText.quoted(line.label)),"t0":\#(JSONText.number(line.t0)),"t1":\#(JSONText.number(line.t1)),"text":\#(JSONText.quoted(line.text))}"#
            }.joined(separator: ",")
            let agendaText = agendaManual.map { #"{"item":\#(JSONText.quoted($0.item)),"status":"\#($0.status.rawValue)"}"# }
                .joined(separator: ",")
            return #"{"t":"turn","reason":"\#(reason.rawValue)","elapsed_sec":\#(elapsedSec),"lines":[\#(linesText)],"agenda_manual":[\#(agendaText)],"notes":\#(JSONText.quoted(notes))}"#
        case .pause(let on):
            return #"{"t":"pause","on":\#(on)}"#
        case .detail(let cardID):
            return #"{"t":"detail","card_id":\#(JSONText.quoted(cardID))}"#
        case .finish(let elapsedSec, let notes):
            return #"{"t":"finish","elapsed_sec":\#(elapsedSec),"notes":\#(JSONText.quoted(notes))}"#
        case .quit:
            return #"{"t":"quit"}"#
        }
    }

    public func data() -> Data {
        Data((line() + "\n").utf8)
    }
}

/// События ← stdout (§2.3). Неизвестный t → nil (как DictationEvent.parse).
public enum PrompterEvent: Equatable {
    case ready(contextTokens: Int, materials: [MaterialInfo], warnings: [String], profileEmpty: Bool)
    case warm(ok: Bool, ttftMs: Int?, message: String?)
    case card(PromptCard, turn: Int)
    case cards(turn: Int, cards: [PromptCard], agenda: [AgendaItem], questionPending: Bool,
               usage: PrompterUsage, firstCardMs: Int?, latencyMs: Int, costUSD: Double?, costTotalUSD: Double)
    case detail(cardID: String, text: String)
    case waiting(reason: String, sec: Int)
    case paused(reason: String, costUSD: Double, ceilingUSD: Double)
    case outcome(CallOutcome?, message: String?, usage: PrompterUsage?, costTotalUSD: Double)
    case error(message: String, retryInSec: Int?, fatal: Bool, turn: Int?)

    public static func parse(line: String) -> PrompterEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["t"] as? String
        else { return nil }
        switch kind {
        case "ready":
            let materials = (obj["materials"] as? [[String: Any]] ?? []).map {
                MaterialInfo(name: $0["name"] as? String ?? "",
                             kind: $0["kind"] as? String ?? "",
                             tokens: ($0["tokens"] as? NSNumber)?.intValue ?? 0,
                             warning: $0["warning"] as? String)
            }
            return .ready(contextTokens: (obj["context_tokens"] as? NSNumber)?.intValue ?? 0,
                          materials: materials,
                          warnings: obj["warnings"] as? [String] ?? [],
                          profileEmpty: obj["profile_empty"] as? Bool ?? false)
        case "warm":
            return .warm(ok: obj["ok"] as? Bool ?? false,
                         ttftMs: (obj["ttft_ms"] as? NSNumber)?.intValue,
                         message: obj["message"] as? String)
        case "card":
            guard let card = Self.parseCard(obj["card"]) else { return nil }
            return .card(card, turn: (obj["turn"] as? NSNumber)?.intValue ?? 0)
        case "cards":
            let cards = (obj["cards"] as? [[String: Any]] ?? []).compactMap { Self.parseCard($0) }
            let agenda = (obj["agenda"] as? [[String: Any]] ?? []).compactMap { entry -> AgendaItem? in
                guard let item = entry["item"] as? String,
                      let status = (entry["status"] as? String).flatMap(AgendaStatus.init(rawValue:))
                else { return nil }
                return AgendaItem(item: item, status: status)
            }
            let flags = obj["flags"] as? [String: Any] ?? [:]
            return .cards(turn: (obj["turn"] as? NSNumber)?.intValue ?? 0,
                          cards: cards,
                          agenda: agenda,
                          questionPending: flags["question_pending"] as? Bool ?? false,
                          usage: Self.parseUsage(obj["usage"]),
                          firstCardMs: (obj["first_card_ms"] as? NSNumber)?.intValue,
                          latencyMs: (obj["latency_ms"] as? NSNumber)?.intValue ?? 0,
                          costUSD: (obj["cost_usd"] as? NSNumber)?.doubleValue,
                          costTotalUSD: (obj["cost_total_usd"] as? NSNumber)?.doubleValue ?? 0)
        case "detail":
            return .detail(cardID: obj["card_id"] as? String ?? "", text: obj["text"] as? String ?? "")
        case "waiting":
            return .waiting(reason: obj["reason"] as? String ?? "?", sec: (obj["sec"] as? NSNumber)?.intValue ?? 0)
        case "paused":
            return .paused(reason: obj["reason"] as? String ?? "?",
                           costUSD: (obj["cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                           ceilingUSD: (obj["ceiling_usd"] as? NSNumber)?.doubleValue ?? 0)
        case "outcome":
            let ok = obj["ok"] as? Bool ?? false
            let usage = (obj["usage"] as? [String: Any]).map(Self.parseUsage)
            return .outcome(ok ? CallOutcome(json: obj["outcome"] as? [String: Any] ?? [:]) : nil,
                            message: ok ? nil : obj["message"] as? String,
                            usage: usage,
                            costTotalUSD: (obj["cost_total_usd"] as? NSNumber)?.doubleValue ?? 0)
        case "error":
            return .error(message: obj["message"] as? String ?? "",
                          retryInSec: (obj["retry_in_sec"] as? NSNumber)?.intValue,
                          fatal: obj["fatal"] as? Bool ?? false,
                          turn: (obj["turn"] as? NSNumber)?.intValue)
        default:
            return nil
        }
    }

    private static func parseCard(_ raw: Any?) -> PromptCard? {
        guard let obj = raw as? [String: Any],
              let type = (obj["type"] as? String).flatMap(CardType.init(rawValue:))
        else { return nil }
        return PromptCard(id: obj["id"] as? String ?? "",
                          type: type,
                          priority: (obj["priority"] as? NSNumber)?.intValue ?? 0,
                          text: obj["text"] as? String ?? "",
                          source: obj["source"] as? String ?? "")
    }

    private static func parseUsage(_ raw: Any?) -> PrompterUsage {
        var usage = PrompterUsage()
        guard let obj = raw as? [String: Any] else { return usage }
        usage.promptTokens = (obj["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        usage.completionTokens = (obj["completion_tokens"] as? NSNumber)?.intValue ?? 0
        usage.cachedTokens = (obj["cached_tokens"] as? NSNumber)?.intValue ?? 0
        usage.reasoningTokens = (obj["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        return usage
    }
}
