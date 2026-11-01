import MLaudCore
import NitiUI
import SwiftUI

/// iPhone: приём по локальной сети, код сопряжения на экране, журнал принятого.
struct PhoneScreen: View {
    @Bindable var model: AppModel
    @State private var pairing: PairingInfo?

    var body: some View {
        @Bindable var settings = model.settings
        Screen("iPhone") {
            Panel {
                HStack(spacing: Niti.Spacing.s3) {
                    Toggle("Принимать записи с iPhone", isOn: $settings.phoneSyncEnabled)
                        .toggleStyle(.checkbox)
                    Spacer()
                    statePill
                }
                Hint("Прямой приём по локальной сети — замена транзиту через iCloud. Принятое кладётся в inbox и обрабатывается сразу.")
            }
            HStack(alignment: .top, spacing: Niti.Spacing.s4) {
                Panel("Связь с телефоном") {
                    if let pairing {
                        VStack(alignment: .center, spacing: Niti.Spacing.s3) {
                            if let qr = pairing.qr {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 200, height: 200)
                            }
                            Hint("Отсканируй код в MLaud на iPhone. Если камера недоступна — введи вручную:")
                            Text(pairing.manualCode)
                                .font(Niti.Typography.base.monospaced())
                                .foregroundStyle(Niti.Colors.text)
                                .textSelection(.enabled)
                            Hint("Код — это ключ к записям. Показывай его только своему телефону.")
                            Button("Сменить код…") { model.commands?.regeneratePairing(); reload() }
                                .buttonStyle(.nitiDanger)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Hint("Код связи не готов — см. уведомления.")
                    }
                }
                .frame(maxWidth: .infinity)
                Panel("Принято") {
                    if model.phoneReceipts.isEmpty {
                        Hint("с телефона ещё ничего не приходило")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.phoneReceipts.prefix(30)) { receipt in
                                NitiRow {
                                    HStack(spacing: Niti.Spacing.s3) {
                                        Text(Format.dayTime(receipt.receivedAt))
                                            .font(Niti.Typography.sm.monospacedDigit())
                                            .foregroundStyle(Niti.Colors.subtle)
                                        Text(receipt.name)
                                            .font(Niti.Typography.md)
                                            .foregroundStyle(Niti.Colors.text)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(Format.bytes(receipt.size))
                                            .font(Niti.Typography.sm)
                                            .foregroundStyle(Niti.Colors.muted)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        pairing = model.commands?.pairing()
    }

    private var statePill: some View {
        Group {
            if !model.settings.phoneSyncEnabled {
                NitiStatusPill("приём выключен", tone: .muted)
            } else {
                switch model.phone {
                case .disabled: NitiStatusPill("выключен", tone: .muted)
                case .starting: NitiStatusPill("запускаюсь…", tone: .accent)
                case .listening(let port): NitiStatusPill("жду записи · порт \(port)", tone: .success, systemImage: "antenna.radiowaves.left.and.right")
                case .failed(let reason): NitiStatusPill("ошибка — \(reason)", tone: .danger)
                }
            }
        }
    }
}
