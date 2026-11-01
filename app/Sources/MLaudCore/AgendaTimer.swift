import Foundation

/// FR-12.7: time-карточки на 50/80/100 % считаются локально, без модели; таймерные ходы
/// (FP:544) — каждые `timerEvery` секунд и на тех же отметках, один раз на отметку.
public final class AgendaTimer {
    private let expectedMin: Int
    private var agenda: [BriefAgendaEntry]
    private let timerEvery: TimeInterval
    private var statuses: [AgendaItem] = []
    private var shownMarks: Set<Int> = []          // проценты, чьи карточки уже показаны
    private var firedMarks: Set<Int> = []          // проценты, по которым уже был таймерный ход
    private var lastTimerElapsed: TimeInterval = -.infinity

    public init(expectedMin: Int, agenda: [BriefAgendaEntry], timerEvery: TimeInterval = 300) {
        self.expectedMin = expectedMin
        self.agenda = agenda
        self.timerEvery = timerEvery
    }

    /// Текущие статусы повестки — от модели и от рук.
    public func update(agenda: [AgendaItem]) {
        self.statuses = agenda
    }

    private func status(byText text: String) -> AgendaStatus? {
        statuses.first { $0.item == text }?.status
    }

    /// Карточки, которые пора показать (каждая один раз): id "t.50"/"t.80"/"t.100".
    public func dueCards(elapsed: TimeInterval) -> [PromptCard] {
        var cards: [PromptCard] = []
        for percent in [50, 80, 100] where !shownMarks.contains(percent) {
            let threshold = Double(percent) / 100.0 * Double(expectedMin) * 60
            guard elapsed >= threshold else { continue }
            shownMarks.insert(percent)
            let pending = agenda.filter { status(byText: $0.text) ?? .pending == .pending }
            let notClosed = agenda.filter {
                let s = status(byText: $0.text) ?? .pending
                return s != .done
            }
            let text: String
            switch percent {
            case 50:
                text = pending.isEmpty ? "Половина времени. Все пункты начаты."
                                      : "Половина времени. Не начаты: \(pending.map(\.text).joined(separator: ", "))."
            case 80:
                text = pending.isEmpty ? "80 % времени. Все пункты начаты."
                                       : "80 % времени. Не начаты: \(pending.map(\.text).joined(separator: ", "))."
            default:
                text = notClosed.isEmpty ? "Время вышло. Все пункты закрыты."
                                         : "Время вышло. Не закрыты: \(notClosed.map(\.text).joined(separator: ", "))."
            }
            cards.append(PromptCard(id: "t.\(percent)", type: .time, priority: 1, text: text))
        }
        return cards
    }

    /// true один раз на каждые timerEvery секунд и на 50/80/100 %, не дважды на одном значении.
    public func isTimerTurn(elapsed: TimeInterval) -> Bool {
        let byInterval = elapsed >= lastTimerElapsed + timerEvery
        let byMark = [50, 80, 100].contains { percent in
            !firedMarks.contains(percent)
                && elapsed >= Double(percent) / 100.0 * Double(expectedMin) * 60
        }
        guard byInterval || byMark else { return false }
        lastTimerElapsed = elapsed
        for percent in [50, 80, 100] where elapsed >= Double(percent) / 100.0 * Double(expectedMin) * 60 {
            firedMarks.insert(percent)
        }
        return true
    }

    /// Текст о времени и плане повестки — для таймерного хода модели.
    public static func planText(agenda: [BriefAgendaEntry], statuses: [AgendaItem], elapsed: TimeInterval,
                                expectedMin: Int) -> String {
        var lines = ["Прошло \(Int(elapsed / 60)) из \(expectedMin) мин."]
        guard !agenda.isEmpty else { return lines[0] }
        lines.append("Повестка:")
        for entry in agenda {
            let status = statuses.first { $0.item == entry.text }?.status ?? .pending
            let label = status == .pending ? "ждёт" : status == .active ? "идёт" : "закрыт"
            let plan = entry.planMin.map { " (план \($0) мин)" } ?? ""
            lines.append("- \(entry.text) — \(label)\(plan)")
        }
        return lines.joined(separator: "\n")
    }
}
