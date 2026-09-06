import Foundation
import MLaudCore

/// Процесс `python -m mlaud_worker.prompter` и его события (§4.5). Отдельный процесс, не
/// RecognizerProcess: свой протокол, своя смерть и перезапуск (PrompterPolicy.afterCrash),
/// stderr — nullDevice, вся диагностика — событиями и в prompter.log.jsonl.
final class PrompterController {
    struct Dependencies {
        /// module "mlaud_worker.prompter"; extraEnvironment = MLAUD_LLM_KEY + PYTHONUNBUFFERED
        /// (+ MLAUD_PROMPTER_DIR, если задана в окружении приложения); НЕ workerEnvironment().
        let makeCommand: (_ key: String) -> WorkerCommand
        let paths: PrompterPaths
        let now: () -> Date
    }

    private let deps: Dependencies
    private let session: CallSession
    var onEvent: ((PrompterEvent) -> Void)?      // после применения к session (outcome → CallController)
    var onNotify: ((String, String) -> Void)?

    private(set) var connection: LLMConnection?
    private var apiKey: String?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = LineBuffer()
    private var generation = 0
    private var crashTimes: [Date] = []
    private var startCommand: PrompterCommand?
    private var lastSentID: Int?
    private var lastSentAgenda: [AgendaItem] = []
    private var paused = false
    private let ioQueue = DispatchQueue(label: "mlaud.prompter.io")

    init(deps: Dependencies, session: CallSession) {
        self.deps = deps
        self.session = session
    }

    deinit { shutdown() }

    // MARK: - Подготовка

    /// Решение PrompterPolicy.startDecision; .start → запуск процесса и команды start,
    /// статус .starting; иначе статус .off/.disabled (FR-12.16).
    func prepare(brief: Brief?, briefSlug: String?, callDir: URL, mode: String,
                 connections: LLMConnectionsStore, secrets: SecretStore,
                 limits: PrompterCommand.Limits) {
        let decision = PrompterPolicy.startDecision(brief: brief, connections: connections,
                                                    hasKey: { secrets.secret(for: $0) != nil })
        switch decision {
        case .off:
            session.apply(.prompter(.off))
            return
        case .disabled(let reason):
            session.apply(.prompter(.disabled(reason)))
            return
        case .start(let connection):
            self.connection = connection
            self.apiKey = secrets.secret(for: connection.id)
            let command = PrompterCommand.start(
                callDir: callDir.path,
                briefDir: briefSlug.map { deps.paths.brief(slug: $0).deletingLastPathComponent().path } ?? "",
                profile: deps.paths.profile.path,
                templatesDir: deps.paths.templates.path,
                mode: mode,
                expectedMin: brief?.expectedMin ?? 60,
                connection: connection.wire,
                limits: limits)
            startCommand = command
            session.apply(.prompter(.starting))
            launch()
        }
    }

    private func launch() {
        guard let connection, let key = apiKey else {
            session.apply(.prompter(.disabled("нет ключа у подключения «\(connection?.name ?? "?")»")))
            return
        }
        let command = deps.makeCommand(key)
        let process = command.makeProcess()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        generation += 1
        let gen = generation
        buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            let lines = self.buffer.append(data)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                for line in lines {
                    if let event = PrompterEvent.parse(line: line) { self.handle(event) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.terminated(generation: gen) }
        }
        do {
            try process.run()
        } catch {
            session.apply(.prompter(.failed("не удалось запустить подсказчик: \(error.localizedDescription)")))
            return
        }
        self.process = process
        stdinPipe = stdin
        send(startCommand)
    }

    // MARK: - Команды

    private func send(_ command: PrompterCommand?) {
        guard let command, let handle = stdinPipe?.fileHandleForWriting else { return }
        let payload = command.data()
        ioQueue.async {
            try? handle.write(contentsOf: payload)
        }
    }

    private var live: Bool {
        process?.isRunning == true
    }

    /// Новые строки с прошлого отправленного хода (§2.2); lastSentID — максимальный id.
    private func newLines() -> [TranscriptLine] {
        PrompterPolicy.linesSince(session.snapshot.lines, lastSentID: lastSentID)
    }

    private func fire(reason: PrompterCommand.TurnReason) {
        guard live else { return }
        let lines = newLines()
        if let last = lines.last {
            lastSentID = last.id
        }
        let snapshot = session.snapshot.prompter
        let agendaManual = snapshot.agenda.filter { current in
            lastSentAgenda.first { $0.item == current.item }?.status != current.status
        }
        lastSentAgenda = snapshot.agenda
        send(.turn(reason: reason,
                   elapsedSec: Int(session.snapshot.elapsed),
                   lines: lines,
                   agendaManual: agendaManual,
                   notes: snapshot.notes.joined(separator: "\n")))
    }

    /// Закрытая фраза: them → ход, me — только копится (D18).
    func phrase(_ line: TranscriptLine, allLines: [TranscriptLine], elapsed: TimeInterval,
                agendaManual: [AgendaItem], notes: [String]) {
        guard line.ch == .them else { return }
        fire(reason: .themPhrase)
    }

    /// ⌘↩ — ручной ход без дебаунса (FP:543).
    func requestHint() {
        fire(reason: .manual)
    }

    func timerTurn(elapsed: TimeInterval, agendaManual: [AgendaItem], notes: [String]) {
        fire(reason: .timer)
    }

    /// FR-12.8: пауза суфлёра — запросы не идут, транскрипт и запись продолжаются.
    func setPaused(_ on: Bool) {
        paused = on
        send(.pause(on))
        session.apply(.prompter(on ? .pausedByUser : .ready))
    }

    func detail(cardID: String) {
        send(.detail(cardID: cardID))
    }

    func finish(elapsed: TimeInterval, notes: [String]) {
        guard live else { return }
        let snapshot = session.snapshot.prompter
        send(.finish(elapsedSec: Int(elapsed),
                     notes: notes.joined(separator: "\n").isEmpty
                         ? snapshot.notes.joined(separator: "\n")
                         : notes.joined(separator: "\n")))
    }

    func cancelOutcome() {
        session.apply(.outcomeState(.cancelled))
        shutdown()
    }

    /// quit, terminate через 1 с (как DictationController.shutdown).
    func shutdown() {
        guard let process else { return }
        generation += 1
        if process.isRunning {
            send(.quit)
            ioQueue.asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { process.terminate() }
            }
        }
        self.process = nil
        stdinPipe = nil
    }

    // MARK: - События

    private func handle(_ event: PrompterEvent) {
        if let status = PrompterPolicy.status(for: event, current: session.snapshot.prompter.status) {
            session.apply(.prompter(status))
        }
        switch event {
        case .ready(let contextTokens, _, let warnings, let profileEmpty):
            session.apply(.prompterReady(contextTokens: contextTokens, warnings: warnings,
                                         profileEmpty: profileEmpty,
                                         connectionName: connection?.name,
                                         briefTitle: session.snapshot.title))
        case .card(let card, let turn):
            session.apply(.card(card, turn: turn))
        case .cards(let turn, let cards, let agenda, let questionPending, let usage,
                    let firstCardMs, let latencyMs, _, let costTotal):
            session.apply(.cards(turn: turn, cards: cards, agenda: agenda,
                                 questionPending: questionPending, usage: usage,
                                 firstCardMs: firstCardMs, latencyMs: latencyMs,
                                 costTotalUSD: costTotal))
        case .detail(let cardID, let text):
            session.apply(.detail(cardID: cardID, text: text))
        case .outcome(let outcome, _, _, _):
            if let outcome {
                session.apply(.outcome(outcome))
            } else {
                session.apply(.outcomeState(.failed("итоги не получились")))
            }
        default:
            break
        }
        onEvent?(event)
    }

    private func terminated(generation gen: Int) {
        guard gen == generation else { return }
        process = nil
        stdinPipe = nil
        guard session.snapshot.phase == .running || session.snapshot.phase == .finishing else { return }
        let now = deps.now()
        crashTimes.append(now)
        switch PrompterPolicy.afterCrash(history: crashTimes, now: now) {
        case .restart(let attempt):
            session.apply(.prompter(.crashed(attempt: attempt)))
            onNotify?("Суфлёр", "подсказчик перезапущен, история подсказок начата заново")
            launch()
        case .giveUp:
            session.apply(.prompter(.failed("подсказчик остановлен: перезапуски исчерпаны")))
        }
    }
}
