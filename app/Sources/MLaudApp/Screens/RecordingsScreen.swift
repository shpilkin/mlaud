import MLaudCore
import NitiUI
import SwiftUI

/// Записи: архив транскриптов. Период — меню по годам (вкладки на каждый месяц не
/// масштабируются), поиск — по всем периодам сразу: имя, говорящие, дата.
struct RecordingsScreen: View {
    @Bindable var model: AppModel
    /// nil — самый свежий период; `allPeriods` — все.
    @State private var period: String?
    @State private var query = ""

    static let allPeriods = "*"

    private var groups: [(period: String, items: [Recording])] { model.recordingsGrouped }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var currentPeriod: String? {
        period == Self.allPeriods ? nil : (period ?? groups.first?.period)
    }

    /// Что показывать: при поиске или «Все записи» — все периоды, иначе один.
    private var visible: [(period: String, items: [Recording])] {
        let source = period == Self.allPeriods || !trimmedQuery.isEmpty
            ? groups : groups.filter { $0.period == currentPeriod }
        guard !trimmedQuery.isEmpty else { return source }
        return source.compactMap { group in
            let items = group.items.filter { RecordingIndex.matches($0, query: trimmedQuery) }
            return items.isEmpty ? nil : (group.period, items)
        }
    }

    var body: some View {
        Screen("Записи") {
            if groups.isEmpty {
                NitiEmptyState(systemImage: "waveform.and.magnifyingglass",
                               title: "Записей пока нет",
                               message: "Здесь появится всё, что обработал конвейер: транскрипт, субтитры, говорящие.")
            } else {
                HStack(spacing: Niti.Spacing.s3) {
                    PeriodMenu(periods: groups.map(\.period), selection: $period, current: currentPeriod)
                    NitiField("Поиск: имя, кто говорил, дата", text: $query)
                        .frame(maxWidth: 360)
                    if !query.isEmpty {
                        NitiIconButton(systemName: "xmark.circle.fill", accessibilityLabel: "Очистить поиск") {
                            query = ""
                        }
                    }
                    Spacer()
                }
                if visible.isEmpty {
                    NitiEmptyState(systemImage: "magnifyingglass",
                                   title: "Ничего не нашлось",
                                   message: "Поиск идёт по имени записи, именам говорящих и дате вида 03.09 или 2026-09-03.")
                } else {
                    ForEach(visible, id: \.period) { group in
                        NitiRowSection(Format.period(group.period),
                                       trailing: "\(group.items.count) \(RussianPlural.form(group.items.count, "запись", "записи", "записей"))")
                        VStack(spacing: 0) {
                            ForEach(group.items) { rec in
                                RecordingRow(recording: rec, model: model)
                            }
                        }
                    }
                }
                Hint("Дата серым — из времени файла: у записей до сентября 2026 нет сайдкара; «—» — файл создан позже своего месяца. Транскрипт и субтитры открываются приложением по умолчанию.")
            }
        } trailing: {
            Button("Обновить") { model.commands?.reloadRecordings() }
                .buttonStyle(.niti)
            Button("Открыть папку") { model.commands?.openResultsFolder() }
                .buttonStyle(.niti)
        }
        .onChange(of: groups.map(\.period)) { _, periods in
            if let period, period != Self.allPeriods, !periods.contains(period) { self.period = nil }
        }
    }
}

/// Выбор периода: «Все записи», затем месяцы по годам — список растёт годами и остаётся
/// коротким в меню, в отличие от вкладок.
private struct PeriodMenu: View {
    let periods: [String]
    @Binding var selection: String?
    /// Период, который показан сейчас (nil — «все»).
    let current: String?
    @State private var hovered = false

    private var years: [(year: String, periods: [String])] {
        var order: [String] = []
        var byYear: [String: [String]] = [:]
        for p in periods {
            let year = RecordingIndex.month(ofPeriod: p).map { String($0.year) } ?? "Прочее"
            if byYear[year] == nil { order.append(year) }
            byYear[year, default: []].append(p)
        }
        return order.map { ($0, byYear[$0] ?? []) }
    }

    var body: some View {
        Menu {
            Toggle("Все записи", isOn: Binding(get: { current == nil },
                                              set: { _ in selection = RecordingsScreen.allPeriods }))
            ForEach(years, id: \.year) { group in
                Section(group.year) {
                    ForEach(group.periods, id: \.self) { p in
                        Toggle(Format.period(p), isOn: Binding(get: { current == p },
                                                                set: { _ in selection = p }))
                    }
                }
            }
        } label: {
            HStack(spacing: Niti.Spacing.s2) {
                Image(systemName: "calendar")
                    .font(.system(size: Niti.IconSize.sm - 2, weight: .medium))
                Text(current.map(Format.period) ?? "Все записи")
                    .font(Niti.Typography.md)
                    .fontWeight(Niti.Weight.medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Niti.Colors.muted)
            }
            .foregroundStyle(Niti.Colors.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Пилюля — снаружи меню: модификаторы на самой метке borderless-стиль не рисует.
        .padding(.horizontal, Niti.Spacing.s4)
        .frame(minHeight: Niti.Layout.minTapTarget)
        .background(
            RoundedRectangle(cornerRadius: Niti.Radius.pill, style: .continuous)
                .fill(hovered ? Niti.Colors.hover : Niti.Colors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Niti.Radius.pill, style: .continuous)
                .strokeBorder(Niti.Colors.border, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}
