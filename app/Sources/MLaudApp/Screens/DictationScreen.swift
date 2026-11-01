import MLaudCore
import NitiUI
import SwiftUI

/// Диктовка: состояние, сочетание клавиш, разрешения с объяснением, запуск отсюда, журнал.
struct DictationScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Screen("Диктовка") {
            Panel {
                HStack(spacing: Niti.Spacing.s3) {
                    statePill
                    Spacer()
                    Button(startTitle) { model.commands?.toggleDictation() }
                        .buttonStyle(model.dictation == .listening ? .nitiDanger : .nitiPrimary)
                        .disabled(!model.settings.dictationEnabled || model.dictation == .starting)
                }
                Hint("Диагностика: если отсюда диктовка идёт, а по клавише — нет, дело в сочетании, а не в микрофоне.")
            }
            Panel("Настройки") {
                NitiFormRow("") {
                    Toggle("Диктовка по горячей клавише", isOn: $settings.dictationEnabled)
                        .toggleStyle(.checkbox)
                }
                NitiFormRow("Сочетание клавиш", hint: "кликни и нажми нужное сочетание; Esc — отмена") {
                    HotKeyRecorderView(combo: $settings.dictationHotKey)
                        .frame(width: 160, height: 24)
                }
                if model.hotKeyFailed {
                    NitiBanner("\(model.settings.dictationHotKey.display) занято другим приложением — выбери другое сочетание.",
                               tone: .danger, systemImage: "keyboard")
                }
            }
            Panel("Разрешения") {
                permissionRow("Микрофон", status: micStatus) {
                    switch model.microphone {
                    case .notDetermined:
                        Button("Разрешить") { model.commands?.requestMicrophone() }
                            .buttonStyle(.niti(.plain, size: .small))
                    case .denied:
                        Button("Открыть настройки") { openPrivacy("Privacy_Microphone") }
                            .buttonStyle(.niti(.plain, size: .small))
                    case .authorized:
                        EmptyView()
                    }
                }
                permissionRow("Универсальный доступ", status: model.accessibilityTrusted ? ("есть", .success) : ("нет", .danger)) {
                    if !model.accessibilityTrusted {
                        Button("Открыть настройки") { model.commands?.openAccessibilitySettings() }
                            .buttonStyle(.niti(.plain, size: .small))
                    }
                }
                if !model.accessibilityTrusted {
                    Hint("""
                    Без «Универсального доступа» набранный текст некуда печатать: система молча выбрасывает нажатия, которые шлёт приложение. \
                    Если MLaud в списке уже стоит с галкой — она относится к прошлой сборке с другой подписью: удали строку кнопкой «−» и добавь /Applications/MLaud.app заново.
                    """)
                }
            }
            Panel("Журнал") {
                if model.dictationLog.isEmpty {
                    Hint("пусто")
                } else {
                    Text(model.dictationLog.joined(separator: "\n"))
                        .font(Niti.Typography.sm.monospaced())
                        .foregroundStyle(Niti.Colors.subtle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Открыть файл") { model.commands?.openDictationLog() }
                    .buttonStyle(.niti(.plain, size: .small))
            }
        }
    }

    private var statePill: some View {
        Group {
            if !model.settings.dictationEnabled {
                NitiStatusPill("выключена", tone: .muted, systemImage: "mic.slash")
            } else {
                switch model.dictation {
                case .off: NitiStatusPill("готова · \(model.settings.dictationHotKey.display)", tone: .neutral, systemImage: "mic")
                case .starting: NitiStatusPill("загружаю модель…", tone: .accent, systemImage: "arrow.triangle.2.circlepath")
                case .listening: NitiStatusPill("слушаю", tone: .danger, systemImage: "mic.fill")
                }
            }
        }
    }

    private var startTitle: String {
        switch model.dictation {
        case .off: return "Начать диктовку отсюда"
        case .starting: return "Загружаю модель…"
        case .listening: return "Закончить"
        }
    }

    private var micStatus: (String, NitiStatusPill.Tone) {
        switch model.microphone {
        case .authorized: return ("разрешён", .success)
        case .denied: return ("запрещён", .danger)
        case .notDetermined: return ("не спрашивали", .neutral)
        }
    }

    private func permissionRow<Action: View>(_ title: String, status: (String, NitiStatusPill.Tone),
                                             @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: Niti.Spacing.s3) {
            Text(title)
                .font(Niti.Typography.base)
                .foregroundStyle(Niti.Colors.text)
                .frame(width: Niti.Layout.formLabelWidth, alignment: .leading)
            NitiStatusPill(status.0, tone: status.1)
            Spacer()
            action()
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
