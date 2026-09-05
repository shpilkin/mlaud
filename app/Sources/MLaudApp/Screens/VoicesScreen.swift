import MLaudCore
import NitiUI
import SwiftUI

/// Голоса: разметка кластеров по карточкам и база людей (feature-speaker-id.md §4.2–4.4).
/// Состояние и действия — в `VoicesModel`; здесь только представление на NitiUI.
struct VoicesScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        VoicesBody(model: model, voices: model.voices)
    }
}

private struct VoicesBody: View {
    let model: AppModel
    @Bindable var voices: VoicesModel

    var body: some View {
        Screen("Голоса", scrolls: false) {
            if !model.settings.identifyEnabled {
                NitiBanner("Подписывание известных голосов выключено: новые транскрипты идут со «Спикер N», карточки у них не появляются.",
                           tone: .info, systemImage: "person.crop.circle.badge.xmark") {
                    Button("В настройки") { model.section = .settings }
                        .buttonStyle(.niti(.plain, size: .small))
                }
            }
            NitiTabs([NitiTabs.Item(VoicesModel.Tab.label, "Разметить", systemImage: "person.crop.rectangle.stack"),
                      NitiTabs.Item(VoicesModel.Tab.people, peopleTitle, systemImage: "person.2")],
                     selection: $voices.tab)
            switch voices.tab {
            case .label: LabelTab(voices: voices)
            case .people: PeopleTab(voices: voices)
            }
        } trailing: {
            Button("Обновить") { voices.reload() }
                .buttonStyle(.niti)
        }
        .onAppear { voices.reload() }
        .onDisappear { voices.stopPlayback() }
    }

    private var peopleTitle: String {
        guard let n = voices.listing?.people.count else { return "Люди" }
        return "Люди (\(n))"
    }
}

// MARK: - Разметить

private struct LabelTab: View {
    @Bindable var voices: VoicesModel

    var body: some View {
        HStack(alignment: .top, spacing: Niti.Spacing.s4) {
            recordingsList
                .frame(width: 240)
            cards
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        footer
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            NitiRowSection("Последние записи",
                           trailing: voices.recordings.isEmpty ? nil : "\(voices.recordings.count)")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(voices.recordings) { rec in
                        RecordingItem(recording: rec, selected: rec.url == voices.selectedURL) {
                            voices.select(rec)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        if let rec = voices.selected {
            VStack(alignment: .leading, spacing: Niti.Spacing.s3) {
                cardsHeader
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                            ForEach(voices.visibleClusters) { cluster in
                                ClusterCard(cluster: cluster, minSpeech: rec.sidecar.minSpeech, voices: voices)
                                    .id(cluster.label)
                            }
                            if let error = rec.sidecar.clipsError {
                                Hint("Образцы аудио не нарезаны: \(error)")
                            }
                        }
                        // Метки кластеров одинаковы у всех записей (SPEAKER_00, …): без своей
                        // идентичности на запись карточки переиспользовались бы вместе с
                        // набранным именем и раскрытым полем.
                        .id(rec.url)
                    }
                    .onChange(of: voices.highlighted) { _, _ in scrollToHighlighted(proxy) }
                    .onChange(of: voices.selectedURL) { _, _ in scrollToHighlighted(proxy) }
                }
            }
        } else if voices.recordings.isEmpty {
            NitiEmptyState(systemImage: "person.wave.2",
                           title: "Пока нечего размечать",
                           message: "Карточки появляются у записей, обработанных с включённым «Подписывать известные голоса» (Настройки), и у старых записей — по кнопке «Разметить старую запись…».")
        } else {
            NitiEmptyState(systemImage: "arrow.left", title: "Выбери запись слева", message: "")
        }
    }

    /// После перехода из «Людей»: карточка уже собрана в новой записи — докрутить до неё.
    private func scrollToHighlighted(_ proxy: ScrollViewProxy) {
        guard let label = voices.highlighted else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(label, anchor: .center) }
        }
    }

    private var cardsHeader: some View {
        HStack(spacing: Niti.Spacing.s3) {
            Text(voices.header)
                .font(Niti.Typography.md)
                .fontWeight(Niti.Weight.semibold)
                .foregroundStyle(Niti.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if voices.hiddenCount > 0 {
                Toggle("показывать убранные (\(voices.hiddenCount))", isOn: $voices.showHidden)
                    .toggleStyle(.checkbox)
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
                    .fixedSize()
            }
            Text("Канал:")
                .font(Niti.Typography.sm)
                .foregroundStyle(Niti.Colors.muted)
                .help("Канал записи: с него берётся образец голоса в базу — телефон, ВКС или другое")
            Picker("Канал записи", selection: $voices.channel) {
                ForEach(VoicesPresentation.channels) { channel in
                    Text(channel.title).tag(channel.value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
        }
    }

    private var footer: some View {
        let busy = voices.busy
        let hasSelection = voices.selected != nil
        return HStack(spacing: Niti.Spacing.s3) {
            Button("Разметить старую запись…") { voices.prepareOld() }
                .buttonStyle(.niti)
                .disabled(busy)
                .help("Записи, обработанные до включения идентификации: транскрипт пересобирается с именами из базы, рядом появляется сайдкар с клипами.")
            Button("Убрать из списка") { voices.forgetSelected() }
                .buttonStyle(.niti)
                .disabled(busy || !hasSelection)
            if busy {
                ProgressView().controlSize(.small)
            }
            Text(voices.status)
                .font(Niti.Typography.sm)
                .foregroundStyle(Niti.Colors.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Переподписать транскрипт") { voices.relabel() }
                .buttonStyle(.niti)
                .disabled(busy || !hasSelection)
                .help("Записать текущие имена в .txt и .srt на диске. После каждой разметки это делается само; кнопка — если файлы правили отдельно.")
            Button("Отправить заново") { voices.resend() }
                .buttonStyle(.niti)
                .disabled(busy || (voices.selected?.sidecar.txt.isEmpty ?? true))
                .help("Отправить .txt этой записи в Telegram ещё раз, уже с именами.")
        }
    }
}

private struct RecordingItem: View {
    let recording: SpeakerRecording
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let pending = recording.sidecar.pendingCount
        NitiRow(bar: pending > 0 ? Niti.Colors.warning : nil, selected: selected, action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.sidecar.base)
                    .font(Niti.Typography.md)
                    .fontWeight(Niti.Weight.medium)
                    .foregroundStyle(Niti.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Format.dayTime(recording.date)) · \(VoicesPresentation.recordingStatus(recording.sidecar))")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(pending > 0 ? Niti.Colors.warning : Niti.Colors.subtle)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Карточка кластера

/// Три состояния: свёрнута (человек убрал кластер: «без имени» / «смесь»), короткий кластер
/// (послушать можно, отпечаток в базу не идёт — FR-8.9), рабочая (поле имени, подтверждение
/// автоузнавания).
private struct ClusterCard: View {
    let cluster: SpeakerCluster
    let minSpeech: Double
    @Bindable var voices: VoicesModel
    @State private var name = ""
    @State private var editing = false

    private var collapsed: Bool { cluster.isCollapsed }
    private var long: Bool { cluster.isLong(minSpeech: minSpeech) && cluster.hasEmbedding }
    private var assigned: String? {
        guard let a = cluster.assigned, !a.isEmpty else { return nil }
        return a
    }

    var body: some View {
        NitiCard(selected: voices.highlighted == cluster.label, dimmed: collapsed) {
            VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                // Строка 1: метка и объём речи, справа — что думает база и кнопки.
                HStack(alignment: .center, spacing: Niti.Spacing.s3) {
                    Text(VoicesPresentation.clusterTitle(cluster))
                        .font(Niti.Typography.md)
                        .fontWeight(Niti.Weight.medium)
                        .foregroundStyle(long && !collapsed ? Niti.Colors.text : Niti.Colors.subtle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                // Строка 2: фрагменты для прослушивания и цитата.
                HStack(alignment: .center, spacing: Niti.Spacing.s3) {
                    clips
                    let subtitle = VoicesPresentation.clusterSubtitle(cluster, minSpeech: minSpeech)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Niti.Typography.sm)
                            .foregroundStyle(Niti.Colors.muted)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Поле имени — пока имя не стоит; подписанному и уверенно узнанному — по карандашу.
                if !collapsed && (editing || VoicesPresentation.needsNameField(cluster)) {
                    nameRow
                }
            }
        }
        .disabled(voices.busy)
        .onAppear { name = assigned ?? "" }
        .onChange(of: cluster.assigned) { _, new in
            name = new ?? ""
            editing = false
        }
        .onChange(of: cluster.effectiveMatch) { _, _ in editing = false }
    }

    /// Фрагменты: по кнопке на каждый, с таймкодом — чтобы выбирать, что слушать.
    private var clips: some View {
        HStack(spacing: Niti.Spacing.s1) {
            if cluster.clips.isEmpty {
                Button("▶") {}
                    .buttonStyle(.niti(.plain, size: .small))
                    .disabled(true)
            }
            ForEach(cluster.clips.indices, id: \.self) { i in
                let isPlaying = voices.playing == VoicesModel.Playing(label: cluster.label, index: i)
                Button((isPlaying ? "■ " : "▶ ") + VoicesPresentation.clipTitle(cluster, index: i)) {
                    voices.togglePlay(cluster: cluster, index: i)
                }
                .buttonStyle(.niti(.plain, size: .small))
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: Niti.Spacing.s2) {
            if let badge = VoicesPresentation.badge(for: cluster) {
                NitiStatusPill(badge.text, tone: badge.tone)
            }
            if collapsed {
                NitiIconButton(systemName: "pencil", accessibilityLabel: "Вернуть к разметке") {
                    voices.apply(.restore, to: cluster)
                }
                .help("Вернуть к разметке")
                if !cluster.hidden {
                    trash
                }
            } else {
                if assigned != nil {
                    NitiIconButton(systemName: "pencil", accessibilityLabel: "Изменить имя") { editing.toggle() }
                        .help("Изменить имя")
                } else if let m = cluster.effectiveMatch {
                    if !m.sure {
                        Button("Да, он") { voices.apply(.confirm, to: cluster) }
                            .buttonStyle(.niti(.success, size: .small))
                    }
                    Button(m.sure ? "Не он" : "Нет") { voices.apply(.reject, to: cluster) }
                        .buttonStyle(.niti(.plain, size: .small))
                    if m.sure {
                        NitiIconButton(systemName: "pencil", accessibilityLabel: "Другое имя") { editing.toggle() }
                            .help("Другое имя")
                    }
                }
                trash
            }
        }
        .fixedSize()
    }

    /// Корзина: фрагмент не нужен в списке. Клипы остаются до ретенции, вернуть можно.
    private var trash: some View {
        NitiIconButton(systemName: "trash", accessibilityLabel: "Убрать фрагмент из списка") {
            voices.apply(.delete, to: cluster)
        }
        .help("Убрать фрагмент из списка")
    }

    /// Поле имени: пишешь новое или выбираешь из списка. Enter, выбор из списка и «Сохранить» —
    /// одно и то же действие. В узкой карточке два выхода из разметки уходят на вторую строку.
    private var nameRow: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s1) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Niti.Spacing.s2) {
                    nameField.frame(width: 260)
                    peopleMenu
                    saveButton
                    Spacer(minLength: Niti.Spacing.s3)
                    exitButtons
                }
                VStack(alignment: .leading, spacing: Niti.Spacing.s2) {
                    HStack(spacing: Niti.Spacing.s2) {
                        nameField.frame(maxWidth: 280)
                        peopleMenu
                        saveButton
                    }
                    HStack(spacing: Niti.Spacing.s2) { exitButtons }
                }
            }
            if !suggestions.isEmpty {
                HStack(spacing: Niti.Spacing.s1) {
                    ForEach(suggestions, id: \.self) { person in
                        Button(person) { submit(person) }
                            .buttonStyle(.niti(.plain, size: .small))
                    }
                }
            }
        }
    }

    private var nameField: some View {
        NitiField(voices.people.isEmpty ? "Кто это? Имя или инициалы" : "Кто это? Имя или выбери из списка",
                  text: $name)
            .onSubmit { submit() }
    }

    @ViewBuilder
    private var peopleMenu: some View {
        if !voices.people.isEmpty {
            Menu {
                ForEach(voices.people, id: \.self) { person in
                    Button(person) { submit(person) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Выбрать из базы")
        }
    }

    private var saveButton: some View {
        Button("Сохранить") { submit() }
            .buttonStyle(.niti(.primary, size: .small))
            .fixedSize()
    }

    /// Два выхода из разметки — видимыми кнопками, а не в меню: их ищут.
    @ViewBuilder
    private var exitButtons: some View {
        Button("Смесь / неразборчиво") { voices.apply(.mixed, to: cluster) }
            .buttonStyle(.niti(.plain, size: .small))
            .fixedSize()
            .help("В кластере слышно нескольких или не разобрать: в базу не идёт, остаётся «Спикер N».")
        Button("Без имени") { voices.apply(.none, to: cluster) }
            .buttonStyle(.niti(.plain, size: .small))
            .fixedSize()
            .help("Случайный голос: имени не будет, со счётчика снимается.")
    }

    /// Подсказка по буквам: кто из базы похож на набранное.
    private var suggestions: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return Array(voices.people.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }.prefix(5))
    }

    private func submit(_ chosen: String? = nil) {
        let value = (chosen ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != assigned else { return }
        voices.apply(.assign(value), to: cluster)
    }
}

private extension VoicesPresentation.Badge {
    var tone: NitiStatusPill.Tone {
        switch self {
        case .hidden, .unnamed: return .muted
        case .mixed, .unsure: return .warning
        case .assigned, .sure: return .success
        }
    }
}

// MARK: - Люди

private struct PeopleTab: View {
    @Bindable var voices: VoicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Niti.Spacing.s3) {
            if let listing = voices.listing {
                if listing.people.isEmpty {
                    NitiEmptyState(systemImage: "person.2",
                                   title: "В базе пока никого",
                                   message: "Имена появляются, когда ты называешь кластер во вкладке «Разметить».")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(listing.people) { person in
                                PersonRow(person: person, voices: voices)
                                ForEach(person.samples) { sample in
                                    SampleRow(person: person, sample: sample, voices: voices)
                                }
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: Niti.Spacing.s2) {
                    ProgressView().controlSize(.small)
                    Hint("Читаю базу голосов…")
                }
            }
            Hint("Образцы — векторы голоса из размеченных записей, только на этом Mac. Удаление человека удаляет все его образцы. Клик по образцу открывает его кластер в разметке.")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(voices.busy)
    }
}

private struct PersonRow: View {
    let person: VoicePerson
    let voices: VoicesModel

    var body: some View {
        NitiRow {
            HStack(alignment: .firstTextBaseline, spacing: Niti.Spacing.s2) {
                Text(person.name)
                    .font(Niti.Typography.md)
                    .fontWeight(Niti.Weight.semibold)
                    .foregroundStyle(Niti.Colors.text)
                Text(VoicesPresentation.personLine(person))
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
            }
        } actions: {
            Button("Переименовать…") { voices.rename(person) }
                .buttonStyle(.niti(.plain, size: .small))
            Button("Удалить человека") { voices.remove(person) }
                .buttonStyle(.niti(.danger, size: .small))
        }
    }
}

private struct SampleRow: View {
    let person: VoicePerson
    let sample: VoiceSample
    let voices: VoicesModel

    var body: some View {
        NitiRow(action: { voices.reveal(source: sample.sourceFile, label: sample.label) }) {
            HStack(spacing: Niti.Spacing.s2) {
                Image(systemName: "waveform")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                    .padding(.leading, Niti.Spacing.s4)
                Text(VoicesPresentation.sampleLine(sample))
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } actions: {
            Button("Показать в разметке") { voices.reveal(source: sample.sourceFile, label: sample.label) }
                .buttonStyle(.niti(.plain, size: .small))
                .help("Открыть кластер этого образца во вкладке «Разметить» (то же — клик по строке)")
            Button("Удалить образец") { voices.remove(sample, of: person) }
                .buttonStyle(.niti(.danger, size: .small))
        }
    }
}
