import MLaudCore
import NitiUI
import SwiftUI

/// Экран итогов звонка (UX:304-309): редактируемый текст, оценка по критериям, заметки;
/// кнопки «Отправить в Telegram», «Открыть папку», «Скопировать».
struct OutcomeScreen: View {
    @Bindable var model: AppModel
    let callID: String
    @State private var markdown: String = ""
    @State private var saveWork: DispatchWorkItem?
    @State private var outcome: CallOutcome?

    var body: some View {
        Screen("Итоги", leading: { BackButton(label: "Суфлёр") { model.prompterView = .list } }) {
            if let outcome {
                editor(outcome)
            } else {
                NitiEmptyState(systemImage: "doc.text.magnifyingglass",
                               title: "Итогов нет",
                               message: outcomeMessage)
                if let record {
                    CallFacts(record: record)
                }
            }
        } trailing: {
            Button("Отправить в Telegram") { model.commands?.sendOutcomeToTelegram(callID: callID) }
                .buttonStyle(.nitiPrimary)
                .disabled(!hasOutcome)
            Button("Скопировать") { model.commands?.copyOutcome(callID: callID) }
                .buttonStyle(.niti(.plain, size: .small))
            Button("Папка звонка") { model.commands?.openCallFolder(callID) }
                .buttonStyle(.niti(.plain, size: .small))
        }
        .onAppear {
            // Итоги читаются из папки звонка: MLAUD_PROMPTER_DIR в --screenshot даёт то же дерево.
            let outcome = CallStore.readOutcome(root: PrompterPaths.resolve().calls, callID: callID)
            self.outcome = outcome
            markdown = outcome?.markdown ?? ""
        }
    }

    private var record: CallRecord? { model.calls.first { $0.callID == callID } }

    private var hasOutcome: Bool { outcome != nil }

    private var outcomeMessage: String {
        switch model.call.prompter.outcomeState {
        case .cancelled: return "Итоги отменили во время звонка — запись сохранилась, итогов нет."
        case .failed: return "Итоги не получились: модель или сеть отказали во время звонка."
        default: return "Звонок шёл без суфлёра или итоги не успели посчитаться до конвертации записи."
        }
    }

    @ViewBuilder
    private func editor(_ outcome: CallOutcome) -> some View {
        if let record {
            CallFacts(record: record)
        }
        HStack(spacing: Niti.Spacing.s3) {
            goalPill(outcome.goalResult)
            Text(outcome.reason).font(Niti.Typography.sm).foregroundStyle(Niti.Colors.muted)
        }
        TextEditor(text: $markdown)
            .font(Niti.Typography.base)
            .frame(minHeight: 260)
            .border(Niti.Colors.border)
            .onChange(of: markdown) { _, text in
                saveWork?.cancel()
                let work = DispatchWorkItem { model.commands?.saveOutcome(callID: callID, markdown: text) }
                saveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
    }

    @ViewBuilder
    private func goalPill(_ goal: GoalResult) -> some View {
        switch goal {
        case .achieved: NitiStatusPill("цель достигнута", tone: .success)
        case .partial: NitiStatusPill("частично", tone: .warning)
        case .not: NitiStatusPill("не достигнута", tone: .danger)
        }
    }
}

private struct CallFacts: View {
    let record: CallRecord

    var body: some View {
        NitiFormRow("Звонок") {
            HStack(spacing: Niti.Spacing.s3) {
                Text(Format.dayTime(record.startedAt))
                Text(record.durationSec.map(Format.duration) ?? "")
                if let stats = record.prompter, stats.enabled {
                    Text("\(stats.turns) ходов · $\(String(format: "%.3f", stats.costUSD))")
                }
            }
            .font(Niti.Typography.sm)
            .foregroundStyle(Niti.Colors.subtle)
        }
        if let stats = record.prompter, stats.enabled, !stats.connection.isEmpty {
            NitiFormRow("Суфлёр") {
                Text("\(stats.connection) · \(stats.llmModel) · кэш \(stats.cachedTokens) из \(stats.promptTokens) ток.")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
            }
        }
    }
}
