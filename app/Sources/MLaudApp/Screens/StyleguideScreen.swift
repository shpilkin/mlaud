import NitiUI
import SwiftUI

/// Витрина токенов и компонентов. Правило Niti: добавил компонент — добавь сюда.
/// Тема — системная; вторая тема снимается режимом `--screenshot`.
struct StyleguideScreen: View {
    @State private var tab = "one"
    @State private var field = ""
    @State private var toast: String?

    var body: some View {
        Screen("Витрина") {
            Panel("Цвет") {
                HStack(spacing: Niti.Spacing.s2) {
                    swatch("bg", Niti.Colors.bg); swatch("surface", Niti.Colors.surface)
                    swatch("card", Niti.Colors.card); swatch("hover", Niti.Colors.hover)
                    swatch("border", Niti.Colors.border); swatch("chip", Niti.Colors.chip)
                    swatch("accent", Niti.Colors.accent); swatch("accentWeak", Niti.Colors.accentWeak)
                    swatch("success", Niti.Colors.success); swatch("warning", Niti.Colors.warning)
                    swatch("danger", Niti.Colors.danger); swatch("delegated", Niti.Colors.delegated)
                }
            }
            Panel("Типографика") {
                Text("xs 11 — капс-метки").font(Niti.Typography.xs)
                Text("sm 12 — плашки, счётчики").font(Niti.Typography.sm)
                Text("md 13 — текст списков").font(Niti.Typography.md)
                Text("base 13 — базовый текст").font(Niti.Typography.base)
                Text("lg 14 semibold — заголовок карточки").font(Niti.Typography.lg)
                Text("xl 18 — заголовок экрана").font(Niti.Typography.xl)
                Text("2xl 22 — крупный заголовок").font(Niti.Typography.xxl)
                Text("18:42 / 60").font(Niti.Typography.timer)
            }
            Panel("Кнопки") {
                HStack(spacing: Niti.Spacing.s2) {
                    Button("plain") {}.buttonStyle(.niti)
                    Button("primary") {}.buttonStyle(.nitiPrimary)
                    Button("success") {}.buttonStyle(.nitiSuccess)
                    Button("danger") {}.buttonStyle(.nitiDanger)
                    Button("small") {}.buttonStyle(.niti(.plain, size: .small))
                    Button("disabled") {}.buttonStyle(.nitiPrimary).disabled(true)
                    NitiIconButton(systemName: "gearshape", accessibilityLabel: "icon") {}
                }
            }
            Panel("Плашки, чипы, метки") {
                HStack(spacing: Niti.Spacing.s2) {
                    NitiStatusPill("neutral"); NitiStatusPill("accent", tone: .accent)
                    NitiStatusPill("success", tone: .success, systemImage: "checkmark")
                    NitiStatusPill("warning", tone: .warning); NitiStatusPill("danger", tone: .danger)
                    NitiStatusPill("muted", tone: .muted); NitiBadge(3); NitiTag("тег")
                }
                HStack(spacing: Niti.Spacing.s2) {
                    NitiChip(systemName: "bubble.left", tone: .accent)
                    NitiChip(systemName: "questionmark.circle", tone: .delegated)
                    NitiChip(systemName: "doc.text", tone: .neutral)
                    NitiChip(systemName: "arrow.right.circle", tone: .success)
                    NitiChip(systemName: "arrow.uturn.left", tone: .warning)
                    NitiChip(systemName: "exclamationmark.triangle", tone: .danger)
                }
            }
            Panel("Баннеры и тост") {
                NitiBanner("info — состояние, которое остаётся", tone: .info, systemImage: "info.circle")
                NitiBanner("ok", tone: .ok, systemImage: "checkmark.circle")
                NitiBanner("warn — нет разрешения", tone: .warn, systemImage: "exclamationmark.triangle") {
                    Button("Действие") {}.buttonStyle(.niti(.plain, size: .small))
                }
                NitiBanner("danger", tone: .danger, systemImage: "xmark.octagon")
                Button("Показать тост") { toast = "Скопировано" }.buttonStyle(.niti)
            }
            Panel("Строки, вкладки, формы") {
                NitiTabs([.init("one", "Одна", systemImage: "1.circle"), .init("two", "Вторая"), .init("three", "Третья")],
                         selection: $tab)
                NitiRowSection("секция", trailing: "3")
                VStack(spacing: 0) {
                    NitiRow(bar: Niti.Colors.accent, action: {}) {
                        Text("строка с полосой и действиями по наведению").font(Niti.Typography.md)
                    } actions: {
                        NitiIconButton(systemName: "doc.text", accessibilityLabel: "a") {}
                        NitiIconButton(systemName: "trash", accessibilityLabel: "b", tint: Niti.Colors.danger) {}
                    }
                    NitiRow(selected: true) { Text("выбранная строка").font(Niti.Typography.md) }
                    NitiRow { Text("обычная строка").font(Niti.Typography.md) }
                }
                NitiFormRow("Подпись", hint: "подсказка серым") {
                    NitiField("плейсхолдер", text: $field).frame(maxWidth: 320)
                }
                NitiFormRow("") {
                    Toggle("чекбокс", isOn: .constant(true)).toggleStyle(.checkbox)
                }
                HStack(spacing: Niti.Spacing.s5) {
                    NitiKeyValue("Подпись", "Значение")
                    NitiKeyValue("Тон", "danger", tone: Niti.Colors.danger)
                }
            }
            Panel("Уровни и таймер звонка") {
                HStack(spacing: Niti.Spacing.s5) {
                    NitiLevelMeter(level: 0, label: "тишина")
                    NitiLevelMeter(level: 0.006, label: "порог")
                    NitiLevelMeter(level: 0.05, label: "речь")
                    NitiLevelMeter(level: 0.3, label: "громко")
                    NitiLevelMeter(level: 1, label: "предел")
                }
                HStack(spacing: Niti.Spacing.s5) {
                    NitiTimerLabel(seconds: 1122)
                    NitiTimerLabel(seconds: 1122, plan: 3600)
                    NitiTimerLabel(seconds: 3725, plan: 3600)
                }
            }
            Panel("Карточки и пустое состояние") {
                NitiCard(selected: true) { Text("выбранная карточка").font(Niti.Typography.md) }
                NitiCard(hoverable: true) { Text("карточка с hover").font(Niti.Typography.md) }
                NitiCard(dimmed: true) { Text("приглушённая").font(Niti.Typography.md) }
                NitiEmptyState(systemImage: "tray", title: "Пусто", message: "Подсказка, что сделать")
            }
        }
        .nitiToast($toast)
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: Niti.Radius.xs)
                .fill(color)
                .frame(width: 44, height: 28)
                .overlay(RoundedRectangle(cornerRadius: Niti.Radius.xs).strokeBorder(Niti.Colors.border))
            Text(name).font(Niti.Typography.xs).foregroundStyle(Niti.Colors.muted)
        }
    }
}
