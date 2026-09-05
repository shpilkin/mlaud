import MLaudCore
import NitiUI
import SwiftUI

/// Главное окно: сайдбар с разделами слева, экран раздела справа.
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            NitiSidebar {
                Text("MLaud")
                    .font(Niti.Typography.lg)
                    .foregroundStyle(Niti.Colors.text)
                    .padding(.horizontal, Niti.Spacing.s3)
                    .padding(.vertical, Niti.Spacing.s2)
                ForEach(AppSection.primary) { section in
                    navItem(section)
                }
                Spacer(minLength: 0)
                NitiNavSeparator()
                navItem(.settings)
            }
            Rectangle()
                .fill(Niti.Colors.border)
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Niti.Colors.bg)
        .nitiToast($model.toast)
    }

    private func navItem(_ section: AppSection) -> some View {
        NitiNavItem(section.title, systemImage: section.systemImage,
                    selected: model.section == section,
                    trailing: model.sidebarTrailing(for: section).navTrailing) {
            // ⌥-клик по «Настройки» — витрина компонентов (ux-app.md §2.5).
            if section == .settings, NSEvent.modifierFlags.contains(.option) {
                model.section = .styleguide
            } else {
                model.section = section
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .overview: OverviewScreen(model: model)
        case .recordings: RecordingsScreen(model: model)
        case .prompter: PrompterScreen()
        case .voices: VoicesScreen(model: model)
        case .dictation: DictationScreen(model: model)
        case .phone: PhoneScreen(model: model)
        case .notifications: NotificationsScreen(model: model)
        case .settings: SettingsScreen(model: model)
        case .styleguide: StyleguideScreen()
        }
    }
}
