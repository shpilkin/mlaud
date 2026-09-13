import MLaudCore
import NitiUI
import SwiftUI

/// Экран звонка (ux-app.md §4.3.3, только этап 3): шапка с приложением, устройством и
/// таймером; полоса предупреждений; чек-лист до старта; лента транскрипта во время звонка;
/// конвертация и итог после «Стоп»; статусная строка. Карточки подсказок — этап 4.
struct CallScreen: View {
    @Bindable var model: AppModel

    private var call: CallSnapshot { model.call }

    var body: some View {
        Screen(call.title, scrolls: false,
               leading: { backArrow }) {
            toolbar
            banners
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            statusLine
        } trailing: {
            NitiTimerLabel(seconds: call.elapsed, plan: nil)
            primaryButton
        }
    }

    /// Стрелка «назад» слева от заголовка: есть, пока звонок можно отменить без потерь
    /// (готов и итог); в разговоре и конвертации — нет, там путь назад только через «Стоп».
    @ViewBuilder
    private var backArrow: some View {
        if call.phase == .ready {
            BackButton(label: "Суфлёр") { model.commands?.dismissCall() }
        } else if call.phase == .done {
            BackButton(label: "Суфлёр") { model.commands?.dismissCall() }
        }
    }

    // MARK: - Шапка

    @ViewBuilder
    private var primaryButton: some View {
        switch call.phase {
        case .ready:
            Button("Отмена") { model.commands?.dismissCall() }
                .buttonStyle(.niti)
            Button("Старт") { model.commands?.startCall() }
                .buttonStyle(.nitiPrimary)
                .disabled(!call.canStart)
        case .running:
            Button("Стоп") { model.commands?.stopCall() }
                .buttonStyle(.nitiDanger)
        case .finishing:
            Button("Стоп") {}
                .buttonStyle(.nitiDanger)
                .disabled(true)
        case .done:
            Button("Готово") { model.commands?.dismissCall() }
                .buttonStyle(.nitiPrimary)
        case .idle:
            EmptyView()
        }
    }

    /// Режим, приложение звонка, устройство ввода (без выбора — §6 брифа: `AudioCapture` берёт
    /// устройство по умолчанию).
    private var toolbar: some View {
        HStack(spacing: Niti.Spacing.s3) {
            if call.mode == "offline" {
                NitiStatusPill("офлайн", tone: .accent, systemImage: "iphone")
            } else {
                NitiStatusPill("ВКС", tone: .accent, systemImage: "video")
            }
            if call.phase == .ready && call.mode != "offline" {
                Picker("", selection: appSelection) {
                    Text("без звука приложения").tag(Int32?.none)
                    ForEach(model.callApps) { app in
                        Text(app.name).tag(Int32?.some(app.pid))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
                Button("Обновить") { model.commands?.refreshCallApps() }
                    .buttonStyle(.niti(.plain, size: .small))
            } else {
                Label(call.appName ?? "без звука приложения", systemImage: "macwindow")
                    .font(Niti.Typography.md)
                    .foregroundStyle(call.appName == nil ? Niti.Colors.muted : Niti.Colors.text)
                    .lineLimit(1)
            }
            Label(call.inputDeviceName ?? "микрофон по умолчанию", systemImage: "mic")
                .font(Niti.Typography.md)
                .foregroundStyle(Niti.Colors.subtle)
                .lineLimit(1)
                .truncationMode(.middle)
            if let output = call.outputDeviceName {
                Label(output, systemImage: call.headphonesWarning ? "speaker.wave.2" : "headphones")
                    .font(Niti.Typography.md)
                    .foregroundStyle(Niti.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var appSelection: Binding<Int32?> {
        Binding(get: { model.callAppPID }, set: { model.commands?.selectCallApp($0) })
    }

    // MARK: - Полоса предупреждений

    @ViewBuilder
    private var banners: some View {
        if let error = call.error {
            NitiBanner(error, tone: .danger, systemImage: "xmark.octagon")
        }
        if call.headphonesWarning {
            NitiBanner("Без наушников каналы смешаются: динамики попадут в микрофон, и собеседник окажется в обоих каналах.",
                       tone: .warn, systemImage: "headphones")
        }
        if call.phase == .ready || (call.phase == .running && call.elapsed < 60) {
            NitiBanner(CallConsent.line, tone: .info, systemImage: "record.circle")
        }
        if call.mode == "offline", !model.selfVoiceReady {
            NitiBanner("Живая пометка «Я / не я» выключена: в базе голосов нет персоны «я» — все реплики будут «Я». Эталон: 45 с обычным разговорным голосом, с обычного места — как будете говорить в звонке.",
                       tone: .warn, systemImage: "person.crop.circle.badge.exclamationmark")
        }
        prompterBanners
    }

    /// FR-12.16: деградация суфлёра — транскрипт и запись продолжаются (тексты — §1.6 брифа).
    @ViewBuilder
    private var prompterBanners: some View {
        switch call.prompter.status {
        case .disabled(let reason):
            NitiBanner("Суфлёр выключен: \(reason)", tone: .warn, systemImage: "slash.circle") {
                Button("Настройки") {
                    model.section = .settings
                    model.settingsTab = .prompter
                }
                .buttonStyle(.niti(.plain, size: .small))
            }
        case .retrying(let message, let inSec):
            NitiBanner("Модель недоступна: \(message) — повтор через \(inSec) с",
                       tone: .warn, systemImage: "arrow.clockwise")
        case .pausedByCost(let cost, let ceiling):
            NitiBanner("Суфлёр на паузе: $\(String(format: "%.2f", cost)) из потолка $\(String(format: "%.2f", ceiling))",
                       tone: .warn, systemImage: "dollarsign.circle") {
                Button("Настройки") {
                    model.section = .settings
                    model.settingsTab = .prompter
                }
                .buttonStyle(.niti(.plain, size: .small))
            }
        case .crashed(let attempt):
            NitiBanner("Подсказчик перезапускается (\(attempt)/3)…", tone: .warn, systemImage: "arrow.triangle.2.circlepath")
        case .failed(let reason):
            NitiBanner("Подсказчик остановлен: \(reason)", tone: .danger, systemImage: "xmark.octagon")
        case .pausedByUser:
            NitiBanner("Суфлёр на паузе", tone: .info, systemImage: "pause.circle") {
                Button("Продолжить") { model.commands?.togglePrompterPause() }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        case .off, .starting, .warming, .ready, .requesting, .waiting:
            EmptyView()
        }
    }

    /// Эталон «Я» (этап 5): живая пометка работает только с образцом голоса в базе.
    @ViewBuilder
    private var selfVoiceRow: some View {
        NitiRow(bar: model.selfVoiceReady ? Niti.Colors.accent : Niti.Colors.warning) {
            HStack(spacing: Niti.Spacing.s3) {
                Image(systemName: "person.wave.2")
                    .foregroundStyle(Niti.Colors.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ваш голос")
                        .font(Niti.Typography.md)
                        .foregroundStyle(Niti.Colors.text)
                    Text(model.selfVoiceReady
                         ? "эталон в базе: реплики будут помечаться «Я / не я»"
                         : "без эталона все реплики останутся «Я»: 45 с обычным разговорным голосом с обычного места")
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                }
                Spacer(minLength: Niti.Spacing.s2)
                if let sec = model.selfVoiceRecording {
                    ProgressView(value: sec, total: 45)
                        .frame(width: 90)
                    Text("\(Int(45 - sec)) с")
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                        .monospacedDigit()
                    Button("Отмена") { model.commands?.cancelSelfVoiceRecording() }
                        .buttonStyle(.niti(.plain, size: .small))
                } else if model.selfVoiceReady {
                    NitiStatusPill("готово", tone: .success, systemImage: "checkmark")
                } else {
                    Button("Записать 45 с") { model.commands?.recordSelfVoice() }
                        .buttonStyle(.niti(.primary, size: .small))
                }
            }
        }
    }

    /// Режим без брифа: с брифом его задаёт редактор брифа, без — выбор здесь.
    @ViewBuilder
    private var modeRow: some View {
        NitiRow(bar: call.mode == "offline" ? Niti.Colors.accent : Niti.Colors.muted) {
            HStack(spacing: Niti.Spacing.s3) {
                Image(systemName: "waveform")
                    .foregroundStyle(Niti.Colors.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Режим")
                        .font(Niti.Typography.md)
                        .foregroundStyle(Niti.Colors.text)
                    Text(modeHint)
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                }
                Spacer(minLength: Niti.Spacing.s2)
                Picker("", selection: Binding(
                    get: { call.mode },
                    set: { model.commands?.setCallMode($0) })) {
                    Text("ВКС (два канала)").tag("vks")
                    Text("офлайн (один микрофон)").tag("offline")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var modeHint: String {
        call.mode == "offline"
            ? "один микрофон: реплики делятся по голосу «Я / не я» (нужен эталон)"
            : "микрофон + звук приложения: каналы раздельные, голос не анализируется"
    }

    /// Бриф = ключ к суфлёру: без него подсказчика нет (транскрипт и запись работают).
    /// Выбор прямо в чек-листе, чтобы «Начать звонок» не молчал о причине.
    @ViewBuilder
    private var briefRow: some View {
        NitiRow(bar: selectedBrief?.prompter == true ? Niti.Colors.accent : Niti.Colors.warning) {
            HStack(spacing: Niti.Spacing.s3) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Niti.Colors.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Бриф")
                        .font(Niti.Typography.md)
                        .foregroundStyle(Niti.Colors.text)
                    Text(briefHint)
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                }
                Spacer(minLength: Niti.Spacing.s2)
                if model.briefs.isEmpty {
                    Button("Создать…") { model.commands?.newBrief(template: "meeting") }
                        .buttonStyle(.niti(.plain, size: .small))
                } else {
                    Picker("", selection: Binding(
                        get: { model.callBriefSlug },
                        set: { model.commands?.prepareCallBrief($0) })) {
                        Text("без брифа").tag(String?.none)
                        ForEach(model.briefs) { brief in
                            Text(brief.title).tag(String?.some(brief.slug))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private var selectedBrief: BriefSummary? {
        model.briefs.first { $0.slug == model.callBriefSlug }
    }

    private var briefHint: String {
        if model.briefs.isEmpty {
            return "без брифа суфлёр не подсказывает — только транскрипт и запись"
        }
        guard let brief = selectedBrief else {
            return "суфлёр выключен: бриф не выбран"
        }
        return brief.prompter
            ? "суфлёр включится: \(brief.title)"
            : "в брифе суфлёр выключен (поле «Суфлёр» в редакторе)"
    }

    // MARK: - Содержимое по фазе

    @ViewBuilder
    private var phaseContent: some View {
        switch call.phase {
        case .ready: checklist
        case .running: running
        case .finishing: finishing
        case .done: done
        case .idle: EmptyView()
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            NitiRowSection("Перед стартом")
            VStack(spacing: 0) {
                if call.mode == "offline" {
                    selfVoiceRow
                }
                briefRow
                if model.callBriefSlug == nil {
                    modeRow
                }
                NitiRow {
                    checkRow("Микрофон", item: call.microphone) {
                        switch call.microphone {
                        case .unknown, .denied:
                            Button("Разрешить") { model.commands?.requestMicrophone() }
                                .buttonStyle(.niti(.plain, size: .small))
                        default:
                            EmptyView()
                        }
                    }
                }
                if call.mode == "offline" {
                    NitiRow {
                        HStack(spacing: Niti.Spacing.s3) {
                            Image(systemName: "mic")
                                .foregroundStyle(Niti.Colors.subtle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Один микрофон (офлайн)")
                                    .font(Niti.Typography.md)
                                    .foregroundStyle(Niti.Colors.text)
                                Text("звук приложения не нужен; кто говорит — узнаётся по голосу в этапе 5")
                                    .font(Niti.Typography.sm)
                                    .foregroundStyle(Niti.Colors.muted)
                            }
                            Spacer(minLength: 0)
                            NitiStatusPill("не нужно", tone: .muted)
                        }
                    }
                } else {
                    NitiRow {
                        checkRow("Звук приложения", item: call.appAudio) {
                            switch call.appAudio {
                            case .needsRestart:
                                Button("Настройки") { model.commands?.openScreenRecordingSettings() }
                                    .buttonStyle(.niti(.plain, size: .small))
                                Button("Перезапустить") { model.commands?.relaunchApp() }
                                    .buttonStyle(.niti(.primary, size: .small))
                            case .denied:
                                Button("Настройки") { model.commands?.openScreenRecordingSettings() }
                                    .buttonStyle(.niti(.plain, size: .small))
                            case .unavailable:
                                Button("Обновить") { model.commands?.refreshCallApps() }
                                    .buttonStyle(.niti(.plain, size: .small))
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
            }
            if case .needsRestart = call.appAudio {
                Hint("Разрешение «Запись экрана» выдаётся процессу при запуске: без перезапуска система не отдаст звук приложения.")
                    .padding(.top, Niti.Spacing.s2)
            }
            if model.callApps.isEmpty, call.appAudio != .checking {
                Hint("Список приложений пуст: система видит только приложения с окнами — откройте окно приложения звонка и нажмите «Обновить».")
                    .padding(.top, Niti.Spacing.s2)
            }
        }
    }

    private func checkRow<Action: View>(_ title: String, item: CheckItem,
                                        @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: Niti.Spacing.s3) {
            Text(title)
                .font(Niti.Typography.md)
                .foregroundStyle(Niti.Colors.text)
                .frame(width: 150, alignment: .leading)
            checkPill(item)
            Text(checkDetail(item, title: title))
                .font(Niti.Typography.sm)
                .foregroundStyle(Niti.Colors.muted)
                .lineLimit(2)
            Spacer(minLength: Niti.Spacing.s2)
            action()
        }
    }

    @ViewBuilder
    private func checkPill(_ item: CheckItem) -> some View {
        switch item {
        case .unknown: NitiStatusPill("не проверено", tone: .muted)
        case .checking: NitiStatusPill("проверяю…", tone: .accent)
        case .ok: NitiStatusPill("готово", tone: .success, systemImage: "checkmark")
        case .denied: NitiStatusPill("нет разрешения", tone: .danger, systemImage: "xmark")
        case .needsRestart: NitiStatusPill("нужен перезапуск", tone: .warning, systemImage: "arrow.clockwise")
        case .unavailable: NitiStatusPill("нет звука", tone: .warning)
        }
    }

    private func checkDetail(_ item: CheckItem, title: String) -> String {
        switch item {
        case .denied(let hint): return hint
        case .needsRestart: return "Согласие на «Запись экрана» дано — перезапустите MLaud"
        case .unavailable(let reason):
            return title == "Звук приложения" ? "Собеседник: нет звука — можно продолжать (\(reason))" : reason
        case .unknown, .checking, .ok: return ""
        }
    }

    private var running: some View {
        HStack(alignment: .top, spacing: Niti.Spacing.s4) {
            VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                TranscriptFeed(lines: call.lines, tails: call.tails, onRelabel: relabelHandler)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if relabelHandler != nil {
                    Text("Стрелка ⇄ у строки меняет «Я» ↔ «не я» · ⌘⇧S — последняя фраза собеседника")
                        .font(Niti.Typography.xs)
                        .foregroundStyle(Niti.Colors.muted)
                        .padding(.horizontal, Niti.Spacing.s3)
                }
            }
            PrompterColumn(model: model)
                .frame(width: 380)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Этап 5: в офлайне метка строки — догадка по голосу, клик её исправляет.
    private var relabelHandler: ((Int) -> Void)? {
        call.mode == "offline" ? { model.commands?.relabelTranscriptLine(id: $0) } : nil
    }

    private var finishing: some View {
        VStack(spacing: Niti.Spacing.s3) {
            ProgressView()
                .controlSize(.regular)
            if call.prompter.outcomeState == .computing {
                Text("Итоги считаются…")
                    .font(Niti.Typography.lg)
                    .foregroundStyle(Niti.Colors.text)
                Text("Последний ход модели по всей беседе: результат по цели, решения, шаги. Запись ждёт итогов — до 45 с, потом конвертируется.")
                    .font(Niti.Typography.md)
                    .foregroundStyle(Niti.Colors.muted)
                    .multilineTextAlignment(.center)
                Button("Отменить итоги") { model.commands?.cancelOutcome() }
                    .buttonStyle(.niti(.plain, size: .small))
            } else {
                Text("Запись конвертируется…")
                    .font(Niti.Typography.lg)
                    .foregroundStyle(Niti.Colors.text)
                Text("Стерео PCM → AAC, затем файл уедет в inbox. Транскрипт ленты уже сохранён в папке звонка.")
                    .font(Niti.Typography.md)
                    .foregroundStyle(Niti.Colors.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Niti.Spacing.s7)
    }

    private var done: some View {
        Panel("Звонок завершён") {
            if let result = call.result {
                HStack(spacing: Niti.Spacing.s3) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: Niti.IconSize.lg, weight: .medium))
                        .foregroundStyle(Niti.Colors.success)
                    VStack(alignment: .leading, spacing: Niti.Spacing.s1) {
                        Text("Файл отправлен в inbox: \(result.lastPathComponent)")
                            .font(Niti.Typography.base)
                            .foregroundStyle(Niti.Colors.text)
                        HStack(spacing: Niti.Spacing.s2) {
                            NitiStatusPill("обрабатывается", tone: .accent)
                            Text("транскрипт с тайм-кодами появится в «Записях», доставка — как у обычной записи")
                                .font(Niti.Typography.sm)
                                .foregroundStyle(Niti.Colors.muted)
                        }
                    }
                }
            } else {
                Text("Запись не сохранена" + (call.error.map { ": \($0)" } ?? ""))
                    .font(Niti.Typography.base)
                    .foregroundStyle(Niti.Colors.danger)
            }
            HStack(spacing: Niti.Spacing.s2) {
                if let result = call.result {
                    Button("Показать в Finder") { model.commands?.revealInFinder(result) }
                        .buttonStyle(.niti)
                }
                if let id = call.callID {
                    Button("Открыть папку звонка") { model.commands?.openCallFolder(id) }
                        .buttonStyle(.niti)
                }
            }
            Hint("Длительность \(Format.duration(call.elapsed)) · записано \(NitiTimerLabel.clock(call.recordedSec)) · каналы: Я / Собеседник")
        }
    }

    // MARK: - Статусная строка

    /// Каналы со статусом — второй строкой: на минимальной ширине окна одна строка не вмещает
    /// «Собеседник: нет звука» с кнопкой рядом с уровнями.
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
            HStack(spacing: Niti.Spacing.s4) {
                recognizerStatus
                NitiLevelMeter(level: call.levels.me, label: "Я")
                if call.mode != "offline" {
                    NitiLevelMeter(level: call.levels.them, label: "Собеседник")
                }
                Text("запись \(NitiTimerLabel.clock(call.recordedSec))")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
                    .monospacedDigit()
                    .fixedSize()
                Spacer(minLength: 0)
            }
            if hasChannelStatus {
                HStack(spacing: Niti.Spacing.s3) {
                    channelStatus(.me, health: call.me)
                    channelStatus(.them, health: call.them)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, Niti.Spacing.s2)
        .overlay(alignment: .top) {
            Rectangle().fill(Niti.Colors.border).frame(height: 1)
        }
    }

    private var recognizerStatus: some View {
        let (text, tone): (String, NitiStatusPill.Tone) = {
            switch call.recognizer {
            case .off: return ("распознавание выключено", .muted)
            case .loading: return ("распознавание загружается…", .accent)
            case .ready: return ("распознавание готово", .success)
            case .restarting(let n): return ("распознавание: перезапуск \(n)", .warning)
            case .failed(let why): return ("распознавание: ошибка — \(why)", .danger)
            }
        }()
        return NitiStatusPill(text, tone: tone)
    }

    private var hasChannelStatus: Bool {
        [call.me, call.them].contains { health in
            switch health {
            case .idle, .flowing: return false
            case .silent, .noAudio, .failed: return true
            }
        }
    }

    @ViewBuilder
    private func channelStatus(_ ch: CallChannel, health: ChannelHealth) -> some View {
        switch health {
        case .idle, .flowing:
            EmptyView()
        case .silent(let since):
            NitiStatusPill("\(ch.defaultLabel): тишина \(Int(since)) с", tone: .muted)
        case .noAudio(let reason):
            HStack(spacing: Niti.Spacing.s2) {
                NitiStatusPill("\(ch.defaultLabel): нет звука", tone: .warning, systemImage: "speaker.slash")
                    .help(reason)
                Text(reason)
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                    .lineLimit(1)
                if ch == .them {
                    Button("Настройки") { model.commands?.openScreenRecordingSettings() }
                        .buttonStyle(.niti(.plain, size: .small))
                }
            }
        case .failed(let reason):
            NitiStatusPill("\(ch.defaultLabel): ошибка — \(reason)", tone: .danger, systemImage: "xmark")
        }
    }
}

/// Лента транскрипта: строки по времени, говорящий цветом («Я» — accent, собеседник —
/// delegated), хвосты текущих фраз серым; автопрокрутка к концу, отпускается, когда
/// пользователь отмотал вверх, и возвращается у нижнего края. В офлайне у строки при
/// наведении появляется ⇄: `onRelabel` перекладывает её «Я» ↔ «не я» (голос мог ошибиться).
private struct TranscriptFeed: View {
    let lines: [TranscriptLine]
    let tails: [CallChannel: String]
    var onRelabel: ((Int) -> Void)?
    @State private var followsTail = true

    private static let bottomID = "tail"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                    if lines.isEmpty, tails.values.allSatisfy(\.isEmpty) {
                        Text("Слушаю… первые фразы появятся после паузы в речи.")
                            .font(Niti.Typography.md)
                            .foregroundStyle(Niti.Colors.muted)
                            .padding(.vertical, Niti.Spacing.s3)
                    }
                    ForEach(lines) { line in
                        Row(time: line.t0, ch: line.ch, label: line.label, text: line.text, tail: false,
                            onTap: onRelabel.map { handler in { handler(line.id) } })
                    }
                    ForEach(CallChannel.allCases, id: \.self) { ch in
                        if let tail = tails[ch], !tail.isEmpty {
                            Row(time: nil, ch: ch, label: ch.defaultLabel, text: tail, tail: true, onTap: nil)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, Niti.Spacing.s2)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 40
            } action: { _, nearBottom in
                followsTail = nearBottom
            }
            .onChange(of: lines.count) { _, _ in scrollToTail(proxy) }
            .onChange(of: tails) { _, _ in scrollToTail(proxy) }
        }
        .background(
            RoundedRectangle(cornerRadius: Niti.Radius.base, style: .continuous)
                .fill(Niti.Colors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Niti.Radius.base, style: .continuous)
                .strokeBorder(Niti.Colors.border, lineWidth: 1)
        )
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private struct Row: View {
        let time: Double?
        let ch: CallChannel
        let label: String
        let text: String
        let tail: Bool
        let onTap: (() -> Void)?
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Niti.Spacing.s2) {
                Text(time.map(NitiTimerLabel.clock) ?? "")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)   // «9:59:59» табличными цифрами 12 pt — 44.9 pt
                Text(label)
                    .font(Niti.Typography.sm)
                    .fontWeight(Niti.Weight.semibold)
                    .foregroundStyle(ch == .me ? Niti.Colors.accent : Niti.Colors.delegated)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)
                Text(text)
                    .font(Niti.Typography.base)
                    .foregroundStyle(tail ? Niti.Colors.muted : Niti.Colors.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onTap {
                    // Кнопка вместо тапа по строке: выделяемый текст перехватывает клик.
                    Button(action: onTap) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(Niti.Typography.base)
                            .foregroundStyle(Niti.Colors.subtle)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22)
                    .opacity(hovering ? 1 : 0)
                    .help("Поменять «Я» ↔ «не я»")
                }
            }
            .padding(.horizontal, Niti.Spacing.s3)
            .padding(.vertical, onTap == nil ? 0 : Niti.Spacing.s1)
            .background(hovering && onTap != nil ? Niti.Colors.chip : Color.clear,
                        in: RoundedRectangle(cornerRadius: Niti.Radius.base, style: .continuous))
            .onHover { hovering = $0 }
        }
    }
}

/// Правая колонка экрана звонка (§4.6, UX:246-284): закреплённые и текущие карточки,
/// повестка чипами, заметка, «Подсказать ⌘↩» и компактный режим.
struct PrompterColumn: View {
    let model: AppModel
    @State private var note = ""

    private var call: CallSnapshot { model.call }
    private var prompter: PrompterSnapshot { call.prompter }

    var body: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s3) {
            prompterBar
            if prompter.status == .off || isDisabled {
                NitiEmptyState(systemImage: "text.bubble",
                               title: "Суфлёр выключен",
                               message: disabledText)
            } else {
                cards
                if !prompter.agenda.isEmpty {
                    agenda
                }
                noteField
                Spacer(minLength: 0)
                controls
            }
        }
        .padding(Niti.Spacing.s3)
        .background(Niti.Colors.card, in: RoundedRectangle(cornerRadius: Niti.Radius.base))
    }

    private var isDisabled: Bool {
        if case .disabled = prompter.status { return true }
        return false
    }

    private var disabledText: String {
        if case .disabled(let reason) = prompter.status { return reason }
        if case .off = prompter.status { return "выключен в брифе — звонок и транскрипт работают" }
        return ""
    }

    /// «Суфлёр: <имя> · N ходов · X с · $Y · кэш Z» + «Пауза/Продолжить» (UX:246).
    private var prompterBar: some View {
        HStack(spacing: Niti.Spacing.s2) {
            Image(systemName: "text.bubble")
                .foregroundStyle(Niti.Colors.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(prompter.connectionName ?? "Суфлёр")
                    .font(Niti.Typography.sm.weight(.medium))
                    .foregroundStyle(Niti.Colors.text)
                    .lineLimit(1)
                HStack(spacing: Niti.Spacing.s2) {
                    Text("\(prompter.turns) ходов")
                    if let latency = prompter.lastLatencyMs {
                        Text(String(format: "%.1f с", Double(latency) / 1000))
                    }
                    if let cached = prompter.lastCachedTokens {
                        Text("кэш \(cached)")
                    }
                    Text(prompter.costUSD > 0 ? String(format: "$%.3f", prompter.costUSD) : "$—")
                }
                .font(Niti.Typography.xs)
                .foregroundStyle(Niti.Colors.muted)
            }
            Spacer(minLength: 0)
            if case .pausedByUser = prompter.status {
                Button("Продолжить") { model.commands?.togglePrompterPause() }
                    .buttonStyle(.niti(.plain, size: .small))
            } else if prompter.status != .off && !isDisabled {
                Button("Пауза") { model.commands?.togglePrompterPause() }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
    }

    /// Закреплённые сверху, затем текущая порция; подсветка первой answer при вопросе (UX:275).
    private var cards: some View {
        ScrollView {
            VStack(spacing: Niti.Spacing.s2) {
                let all = prompter.pinned + prompter.cards
                if all.isEmpty {
                    Text(prompterCardsEmpty)
                        .font(Niti.Typography.sm)
                        .foregroundStyle(Niti.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Niti.Spacing.s3)
                }
                ForEach(all) { card in
                    PromptCardRow(model: model, card: card, prompter: prompter, all: all)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var prompterCardsEmpty: String {
        switch prompter.status {
        case .starting: return "подсказчик запускается…"
        case .warming: return "прогрев модели…"
        case .requesting: return "ход в полёте…"
        case .waiting(_, let sec): return "ждёт лимита \(sec) с"
        default: return "жду фраз собеседника — подсказки появятся по ходу"
        }
    }

    /// Чипы повестки: клик — цикл pending → active → done (UX:277).
    private var agenda: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
            Text("Повестка").font(Niti.Typography.sm.weight(.medium)).foregroundStyle(Niti.Colors.subtle)
            ForEach(prompter.agenda, id: \.item) { item in
                AgendaChip(model: model, item: item)
            }
        }
    }

    private func nextStatus(_ status: AgendaStatus) -> AgendaStatus {
        switch status {
        case .pending: return .active
        case .active: return .done
        case .done: return .pending
        }
    }

    private var noteField: some View {
        HStack(alignment: .firstTextBaseline, spacing: Niti.Spacing.s2) {
            Image(systemName: "square.and.pencil").foregroundStyle(Niti.Colors.subtle)
            TextField("Заметка по ходу (⏎ — добавить)", text: $note)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.commands?.addNote(note)
                    note = ""
                }
        }
    }

    private var controls: some View {
        HStack(spacing: Niti.Spacing.s2) {
            Button("Подсказать ⌘↩") { model.commands?.requestHint() }
                .buttonStyle(.nitiPrimary)
                .disabled(prompter.status == .off || isDisabled)
            Button("Компактно ⌘⇧C") { model.commands?.toggleCompactPanel() }
                .buttonStyle(.niti(.plain, size: .small))
            Spacer()
        }
    }
}

/// Чипы повестки со статусом; клик — сменить статус.
private struct FlowChips: View {
    let items: [(String, AgendaStatus)]
    let onTap: (String, AgendaStatus) -> Void
    let status: (String) -> AgendaStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s1) {
            ForEach(items, id: \.0) { item, next in
                Button {
                    onTap(item, next)
                } label: {
                    HStack(spacing: Niti.Spacing.s1) {
                        Image(systemName: icon(status(item)))
                            .font(Niti.Typography.xs)
                        Text(item)
                            .font(Niti.Typography.sm)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Niti.Spacing.s2)
                    .padding(.vertical, Niti.Spacing.s1)
                    .background(chipColor(status(item)),
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ status: AgendaStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .active: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    private func chipColor(_ status: AgendaStatus) -> Color {
        switch status {
        case .pending: return Niti.Colors.chip
        case .active: return Niti.Colors.accentWeak
        case .done: return Niti.Colors.successBg
        }
    }
}


/// Одна карточка подсказки с проводкой команд; отдельно — чтобы ForEach не тонул в выводе типов.
private struct PromptCardRow: View {
    let model: AppModel
    let card: PromptCard
    let prompter: PrompterSnapshot
    let all: [PromptCard]

    var body: some View {
        let pinned = prompter.pinned.contains { $0.id == card.id }
        let firstAnswer = all.first { $0.type == .answer }?.id == card.id
        NitiPromptCard(
            type: card.type.rawValue,
            text: card.text,
            source: card.source.isEmpty ? nil : card.source,
            pinned: pinned,
            highlighted: card.type == .answer && prompter.questionPending && firstAnswer,
            detail: prompter.details[card.id],
            onPin: { self.onPin(pinned: pinned) },
            onDismiss: { model.commands?.dismissCard(card.id) },
            onCopy: { self.copy() },
            onTap: { model.commands?.requestDetail(card.id) })
    }

    private func onPin(pinned: Bool) {
        if pinned {
            model.commands?.unpinCard(card.id)
        } else {
            model.commands?.pinCard(card.id)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.text, forType: .string)
        model.toast = "Скопировано"
    }
}

/// Чип пункта повестки: клик переводит в следующий статус.
private struct AgendaChip: View {
    let model: AppModel
    let item: AgendaItem

    var body: some View {
        Button {
            model.commands?.setAgenda(item: item.item, status: next)
        } label: {
            HStack(spacing: Niti.Spacing.s1) {
                Image(systemName: icon).font(Niti.Typography.xs)
                Text(item.item).font(Niti.Typography.sm).lineLimit(1)
            }
            .padding(.horizontal, Niti.Spacing.s2)
            .padding(.vertical, Niti.Spacing.s1)
            .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var next: AgendaStatus {
        switch item.status {
        case .pending: return .active
        case .active: return .done
        case .done: return .pending
        }
    }

    private var icon: String {
        switch item.status {
        case .pending: return "circle"
        case .active: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .pending: return Niti.Colors.chip
        case .active: return Niti.Colors.accentWeak
        case .done: return Niti.Colors.successBg
        }
    }
}
