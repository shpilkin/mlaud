import MLaudCore
import NitiUI
import SwiftUI

/// Обзор: состояние конвейера, очередь, последние записи, карантин, доставка, мини-плашки.
struct OverviewScreen: View {
    @Bindable var model: AppModel

    private var state: OverviewState { model.overview }

    var body: some View {
        Screen("Обзор") {
            if !state.hasFolder {
                NitiEmptyState(systemImage: "folder.badge.questionmark",
                               title: "Выбери папку, откуда забирать записи",
                               message: "Приложение следит за ней и транскрибирует всё, что туда попадает: с iPhone, из iCloud или руками.")
                HStack {
                    Spacer()
                    Button("Выбрать папку…") { model.commands?.chooseFolder() }
                        .buttonStyle(.nitiPrimary)
                    Spacer()
                }
            } else {
                pipeline
                if let line = state.deliveryLine {
                    NitiBanner(line, tone: .warn, systemImage: "paperplane") {
                        Button("Отправить сейчас") { model.commands?.processNow() }
                            .buttonStyle(.niti(.plain, size: .small))
                            .disabled(!state.canProcessNow)
                    }
                }
                HStack(alignment: .top, spacing: Niti.Spacing.s4) {
                    VStack(spacing: Niti.Spacing.s4) {
                        queue
                        quarantine
                    }
                    .frame(maxWidth: .infinity)
                    recent
                        .frame(maxWidth: .infinity)
                }
                tiles
            }
        } trailing: {
            if state.hasFolder {
                Button("Обработать сейчас") { model.commands?.processNow() }
                    .buttonStyle(.nitiPrimary)
                    .disabled(!state.canProcessNow)
                    .keyboardShortcut("r", modifiers: .command)
                Button("Выбрать папку…") { model.commands?.chooseFolder() }
                    .buttonStyle(.niti)
            }
        }
    }

    private var pipeline: some View {
        Panel {
            HStack(spacing: Niti.Spacing.s3) {
                NitiStatusPill(state.pipeline.text, tone: state.pipeline.tone.pill,
                               systemImage: state.isProcessing ? "arrow.triangle.2.circlepath" : nil)
                Spacer()
                if case .error = state.status {
                    Button("Открыть лог") { model.commands?.openWorkerLogFile() }
                        .buttonStyle(.niti(.plain, size: .small))
                }
            }
            if case .error = state.status, let line = state.lastLogLine {
                Text(line)
                    .font(Niti.Typography.sm.monospaced())
                    .foregroundStyle(Niti.Colors.danger)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: Niti.Spacing.s2) {
                Image(systemName: "folder")
                    .foregroundStyle(Niti.Colors.muted)
                Text(state.inboxPath ?? "—")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Папка результатов") { model.commands?.openResultsFolder() }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
    }

    private var queue: some View {
        Panel("В очереди") {
            if state.queueLines.isEmpty {
                Hint("пусто — новые файлы подхватятся сами")
            } else {
                ForEach(state.queueLines, id: \.self) { line in
                    HStack(spacing: Niti.Spacing.s2) {
                        Image(systemName: line.contains("iCloud") ? "icloud.and.arrow.down" : "doc.badge.clock")
                            .foregroundStyle(Niti.Colors.subtle)
                        Text(line)
                            .font(Niti.Typography.base)
                            .foregroundStyle(Niti.Colors.text)
                    }
                }
            }
        }
    }

    private var quarantine: some View {
        Panel("Карантин") {
            if state.quarantine.isEmpty {
                Hint("пусто — все файлы обработались")
            } else {
                VStack(spacing: 0) {
                    ForEach(state.quarantine, id: \.self) { url in
                        NitiRow(bar: Niti.Colors.danger) {
                            Text(url.lastPathComponent)
                                .font(Niti.Typography.md)
                                .foregroundStyle(Niti.Colors.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } actions: {
                            Button("Повторить") { model.commands?.retryQuarantine(url) }
                                .buttonStyle(.niti(.plain, size: .small))
                            NitiIconButton(systemName: "magnifyingglass", accessibilityLabel: "Показать в Finder") {
                                model.commands?.revealInFinder(url)
                            }
                        }
                    }
                }
                Hint("«Повторить» переносит файл обратно в inbox.")
            }
        }
    }

    private var recent: some View {
        Panel("Последние") {
            if state.recent.isEmpty {
                Hint("обработанных записей пока нет")
            } else {
                VStack(spacing: 0) {
                    ForEach(state.recent) { rec in
                        RecordingRow(recording: rec, compact: true, model: model)
                    }
                }
                Button("Все записи") { model.section = .recordings }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: Niti.Spacing.s4) {
            tile(.phone, value: phoneLine)
            tile(.dictation, value: dictationLine)
            tile(.voices, value: model.voicesPending > 0
                 ? "\(model.voicesPending) \(RussianPlural.form(model.voicesPending, "голос", "голоса", "голосов")) к разметке"
                 : (model.settings.identifyEnabled ? "всё размечено" : "выключены в настройках"))
        }
    }

    private func tile(_ section: AppSection, value: String) -> some View {
        NitiCard(hoverable: true) {
            HStack(spacing: Niti.Spacing.s3) {
                NitiChip(systemName: section.systemImage, tone: .accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(Niti.Typography.lg)
                        .foregroundStyle(Niti.Colors.text)
                    Text(value)
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.subtle)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Niti.Colors.muted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.section = section }
    }

    private var phoneLine: String {
        guard model.settings.phoneSyncEnabled else { return "приём выключен" }
        switch model.phone {
        case .disabled: return "приём выключен"
        case .starting: return "запускаюсь…"
        case .listening: return model.phoneLastReceived.map { "жду · последняя \(Format.dayTime($0.at))" } ?? "жду записи"
        case .failed(let reason): return "ошибка — \(reason)"
        }
    }

    private var dictationLine: String {
        guard model.settings.dictationEnabled else { return "выключена" }
        switch model.dictation {
        case .off: return "\(model.settings.dictationHotKey.display) готова"
        case .starting: return "загружаю модель…"
        case .listening: return "слушаю"
        }
    }
}

/// Строка записи — общая для Обзора (компактная) и «Записей».
struct RecordingRow: View {
    let recording: Recording
    var compact = false
    let model: AppModel

    var body: some View {
        NitiRow(bar: bar, action: { model.commands?.open(recording.txt) }) {
            HStack(spacing: Niti.Spacing.s3) {
                if recording.dateIsExact || recording.dateFitsPeriod {
                    Text(Format.dayTime(recording.date))
                        .font(Niti.Typography.sm.monospacedDigit())
                        .foregroundStyle(recording.dateIsExact ? Niti.Colors.subtle : Niti.Colors.muted)
                        .frame(width: 80, alignment: .leading)
                        .help(recording.dateIsExact ? Format.full(recording.date) : "дата по времени файла: сайдкара нет")
                } else {
                    Text("—")
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                        .frame(width: 80, alignment: .leading)
                        .help("дата неизвестна: сайдкара нет, а файл создан позже своего месяца")
                }
                if let d = recording.durationSec {
                    Text(Format.duration(d))
                        .font(Niti.Typography.sm.monospacedDigit())
                        .foregroundStyle(Niti.Colors.subtle)
                        .frame(width: 64, alignment: .leading)
                } else if !compact {
                    Text("—")
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                        .frame(width: 64, alignment: .leading)
                }
                Text(recording.speakers.isEmpty ? (compact ? recording.base : "без разметки") : recording.speakers.joined(separator: ", "))
                    .font(Niti.Typography.md)
                    .foregroundStyle(recording.speakers.isEmpty && !compact ? Niti.Colors.muted : Niti.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    if recording.hasPrompter { NitiStatusPill("суфлёр", tone: .accent) }
                    if recording.needsLabeling { NitiStatusPill("к разметке", tone: .warning) }
                }
            }
        } actions: {
            if !compact {
                NitiIconButton(systemName: "doc.text", accessibilityLabel: "Открыть транскрипт") {
                    model.commands?.open(recording.txt)
                }
                if let srt = recording.srt {
                    NitiIconButton(systemName: "captions.bubble", accessibilityLabel: "Открыть субтитры") {
                        model.commands?.open(srt)
                    }
                }
                if let audio = recording.audio {
                    NitiIconButton(systemName: "waveform", accessibilityLabel: "Показать аудио в Finder") {
                        model.commands?.revealInFinder(audio)
                    }
                }
                if recording.hasPrompter {
                    NitiIconButton(systemName: "text.bubble", accessibilityLabel: "Итоги звонка") {
                        model.commands?.open(recording.txt.deletingPathExtension().appendingPathExtension("prompter.md"))
                    }
                }
                if recording.needsLabeling {
                    NitiIconButton(systemName: "person.crop.circle.badge.questionmark", accessibilityLabel: "Разметить голоса") {
                        model.section = .voices
                    }
                }
            }
        }
    }

    private var bar: Color? {
        if recording.needsLabeling { return Niti.Colors.warning }
        if recording.hasPrompter { return Niti.Colors.accent }
        return nil
    }
}
