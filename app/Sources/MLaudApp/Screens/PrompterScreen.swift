import MLaudCore
import NitiUI
import SwiftUI

/// Раздел «Суфлёр» (этап 4, UX:222-309): вне звонка — брифы и звонки, в звонке — экран
/// звонка, из брифа — редактор, после звонка — итоги. Переходы: .list/.editor/.outcome
/// переключает экран; .call — AppDelegate при startCallSetup (D12).
struct PrompterScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.call.phase == .running || model.call.phase == .finishing || model.call.phase == .ready {
            CallScreen(model: model)
        } else {
            switch model.prompterView {
            case .list:
                CallListScreen(model: model)
            case .editor:
                BriefEditorScreen(model: model)
            case .call:
                CallScreen(model: model)
            case .outcome(let callID):
                OutcomeScreen(model: model, callID: callID)
            }
        }
    }
}

/// Брифы и прошедшие звонки (UX:222-227): карточка брифа → редактор; звонок → итоги.
private struct CallListScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Screen("Суфлёр") {
            if model.calls.isEmpty && model.briefs.isEmpty {
                NitiEmptyState(systemImage: "text.bubble",
                               title: "Суфлёр ещё не настраивали",
                               message: "Бриф описывает встречу: цель, собеседника, повестку и материалы — по ним суфлёр подсказывает по ходу. Начните с «Новый бриф».")
            }
            if !model.briefs.isEmpty {
                NitiRowSection("Брифы", trailing: "\(model.briefs.count) \(RussianPlural.form(model.briefs.count, "бриф", "брифа", "брифов"))")
                VStack(spacing: Niti.Spacing.s2) {
                    ForEach(model.briefs) { brief in
                        BriefCard(brief: brief, model: model)
                    }
                }
            }
            if !model.calls.isEmpty {
                NitiRowSection("Звонки", trailing: "\(model.calls.count) \(RussianPlural.form(model.calls.count, "звонок", "звонка", "звонков"))")
                VStack(spacing: 0) {
                    ForEach(model.calls, id: \.callID) { record in
                        CallRow(record: record, model: model)
                    }
                }
            }
        } trailing: {
            Menu {
                ForEach(model.templates.isEmpty ? BriefStore.templateSlugs : model.templates, id: \.self) { slug in
                    Button("Из шаблона «\(slugTitle(slug))»") { model.commands?.newBrief(template: slug) }
                }
            } label: {
                Text("Новый бриф")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(.nitiPrimary)
            Button("Начать звонок") { model.commands?.startCallSetup() }
                .buttonStyle(.niti(.plain, size: .small))
        }
    }

    private func slugTitle(_ slug: String) -> String {
        switch slug {
        case "sale": return "продажа"
        case "interview": return "интервью"
        case "negotiation": return "переговоры"
        case "meeting": return "встреча"
        default: return "свой"
        }
    }
}

private struct BriefCard: View {
    let brief: BriefSummary
    let model: AppModel

    var body: some View {
        NitiCard {
            HStack(spacing: Niti.Spacing.s3) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Niti.Colors.accent)
                VStack(alignment: .leading, spacing: Niti.Spacing.s1) {
                    Text(brief.title.isEmpty ? "Без названия" : brief.title)
                        .font(Niti.Typography.base.weight(.medium))
                        .foregroundStyle(Niti.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: Niti.Spacing.s2) {
                        Text(slugTitle(brief.template))
                        Text(brief.mode == "offline" ? "офлайн" : "ВКС")
                        Text("\(brief.expectedMin) мин")
                        if let last = brief.lastCall {
                            Text("звонок \(Format.dayTime(last))")
                        }
                    }
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                }
                Spacer(minLength: Niti.Spacing.s2)
                NitiStatusPill(brief.prompter ? "суфлёр вкл" : "суфлёр выкл",
                               tone: brief.prompter ? .success : .muted)
                Button("Открыть") { model.commands?.openBrief(slug: brief.slug) }
                    .buttonStyle(.niti(.plain, size: .small))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.commands?.openBrief(slug: brief.slug) }
        }
    }

    private func slugTitle(_ slug: String) -> String {
        switch slug {
        case "sale": return "продажа"
        case "interview": return "интервью"
        case "negotiation": return "переговоры"
        case "meeting": return "встреча"
        default: return "свой"
        }
    }
}

private struct CallRow: View {
    let record: CallRecord
    let model: AppModel

    var body: some View {
        NitiRow(bar: record.recording == nil ? Niti.Colors.warning : nil) {
            HStack(spacing: Niti.Spacing.s3) {
                Text(Format.dayTime(record.startedAt))
                    .font(Niti.Typography.md)
                    .foregroundStyle(Niti.Colors.text)
                    .frame(width: 88, alignment: .leading)
                Text(record.brief ?? "Звонок")
                    .font(Niti.Typography.md)
                    .foregroundStyle(Niti.Colors.text)
                    .lineLimit(1)
                Text(record.durationSec.map(Format.duration) ?? "не завершён")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                Spacer(minLength: Niti.Spacing.s2)
                if record.meetingID != nil {
                    NitiStatusPill("обработан", tone: .success, systemImage: "checkmark")
                } else if record.recording != nil {
                    NitiStatusPill("обрабатывается", tone: .accent)
                }
                goalPill
            }
            .contentShape(Rectangle())
            .onTapGesture { model.commands?.openOutcome(callID: record.callID) }
        } actions: {
            Button("Открыть папку") { model.commands?.openCallFolder(record.callID) }
                .buttonStyle(.niti(.plain, size: .small))
        }
    }

    @ViewBuilder
    private var goalPill: some View {
        switch record.goalResult {
        case .achieved: NitiStatusPill("цель достигнута", tone: .success)
        case .partial: NitiStatusPill("частично", tone: .warning)
        case .not: NitiStatusPill("нет", tone: .danger)
        case nil: NitiStatusPill("без итогов", tone: .muted)
        }
    }
}
