import AppKit
import MLaudCore
import NitiUI
import SwiftUI

/// Компактная панель поверх всех окон (FR-12.9, UX:286-302): не перехватывает фокус —
/// печать в Zoom не прерывается. Верхние карточки, последняя реплика собеседника, таймер,
/// «Подсказать», «Пауза», «Развернуть»; положение/размер запоминаются.
final class CompactPanelController {
    private let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: false)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Закрывается при done/idle (вызывается из applyCallSnapshot).
    func sync(phase: CallPhase) {
        switch phase {
        case .idle, .done:
            if panel?.isVisible == true { close() }
        case .running:
            if model.settings.compactPanelAtStart, panel == nil { show() }
        case .ready, .finishing:
            break
        }
    }

    private func makePanel() -> NSPanel {
        let view = NSHostingView(rootView: CompactView(model: model))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Суфлёр"
        panel.level = .floating
        panel.hidesOnDeactivate = false          // поверх Zoom, не исчезает при переключении
        panel.isMovableByWindowBackground = true
        panel.contentView = view
        panel.setFrameAutosaveName("mlaud.compact")
        if panel.frame.origin == .zero {
            panel.center()
        }
        return panel
    }
}

/// Содержимое панели: таймер, кнопки, до трёх карточек, последняя реплика собеседника.
struct CompactView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: Niti.Spacing.s3) {
            HStack {
                NitiTimerLabel(seconds: model.call.elapsed, plan: planSeconds)
                Spacer()
                Button("Пауза") { model.commands?.togglePrompterPause() }
                    .buttonStyle(.niti(.plain, size: .small))
                Button("Развернуть") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.commands?.startCallSetup()
                }
                .buttonStyle(.niti(.plain, size: .small))
            }
            let cards = (model.call.prompter.pinned + model.call.prompter.cards).prefix(3)
            ForEach(Array(cards)) { card in
                NitiPromptCard(type: card.type.rawValue, text: card.text, source: card.source.isEmpty ? nil : card.source,
                               pinned: model.call.prompter.pinned.contains(where: { $0.id == card.id }),
                               highlighted: false, detail: nil,
                               onPin: { model.commands?.pinCard(card.id) },
                               onDismiss: { model.commands?.dismissCard(card.id) },
                               onCopy: {
                                   NSPasteboard.general.clearContents()
                                   NSPasteboard.general.setString(card.text, forType: .string)
                               },
                               onTap: { model.commands?.requestDetail(card.id) })
            }
            if let last = model.call.lines.last(where: { $0.ch == .them }) {
                Text("\(last.label): \(last.text)")
                    .font(Niti.Typography.sm)
                    .foregroundStyle(Niti.Colors.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Подсказать") { model.commands?.requestHint() }
                .buttonStyle(.nitiPrimary)
        }
        .padding(Niti.Spacing.s4)
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var planSeconds: TimeInterval? { nil }   // план брифа не в снимке; таймер без плана
}
