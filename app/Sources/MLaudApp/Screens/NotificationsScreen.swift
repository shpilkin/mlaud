import MLaudCore
import NitiUI
import SwiftUI

/// Уведомления: журнал сообщений и полный текст выбранного.
struct NotificationsScreen: View {
    @Bindable var model: AppModel
    @State private var selected: UUID?

    private var current: AppNotification? {
        model.notifications.first { $0.id == selected }
    }

    var body: some View {
        Screen("Уведомления") {
            if model.notifications.isEmpty {
                NitiEmptyState(systemImage: "bell.slash",
                               title: "Пусто",
                               message: "Здесь будет всё, о чём приложение сообщало баннером в углу экрана.")
            } else {
                VStack(spacing: 0) {
                    ForEach(model.notifications) { record in
                        NitiRow(bar: record.isRead ? nil : Niti.Colors.accent,
                                selected: record.id == selected,
                                action: { select(record) }) {
                            HStack(alignment: .firstTextBaseline, spacing: Niti.Spacing.s3) {
                                Text(Format.dayTime(record.date))
                                    .font(Niti.Typography.sm.monospacedDigit())
                                    .foregroundStyle(Niti.Colors.subtle)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title)
                                        .font(Niti.Typography.md)
                                        .fontWeight(record.isRead ? Niti.Weight.normal : Niti.Weight.semibold)
                                        .foregroundStyle(Niti.Colors.text)
                                        .lineLimit(1)
                                    Text(record.body.replacingOccurrences(of: "\n", with: " "))
                                        .font(Niti.Typography.sm)
                                        .foregroundStyle(Niti.Colors.subtle)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if record.action == "voices" {
                                    NitiTag("голоса")
                                }
                            }
                        }
                    }
                }
                if let current {
                    Panel(current.title) {
                        Text(current.body)
                            .font(Niti.Typography.base)
                            .foregroundStyle(Niti.Colors.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if current.action == "voices" {
                            Button("Открыть «Голоса»") { model.section = .voices }
                                .buttonStyle(.niti(.plain, size: .small))
                        }
                    }
                }
            }
        } trailing: {
            Button("Пометить всё прочитанным") { model.commands?.markAllNotificationsRead() }
                .buttonStyle(.niti)
                .disabled(model.unreadCount == 0)
            Button("Очистить") { model.commands?.clearNotifications() }
                .buttonStyle(.nitiDanger)
                .disabled(model.notifications.isEmpty)
        }
        .onAppear(perform: reveal)
        .onChange(of: model.revealNotification) { _, _ in reveal() }
    }

    private func select(_ record: AppNotification) {
        selected = record.id
        if !record.isRead { model.commands?.markNotificationRead(record.id) }
    }

    /// Клик по системному баннеру приводит сюда с id записи.
    private func reveal() {
        guard let id = model.revealNotification else { return }
        model.revealNotification = nil
        if let record = model.notifications.first(where: { $0.id == id }) { select(record) }
    }
}
