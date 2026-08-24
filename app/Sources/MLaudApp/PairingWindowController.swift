import AppKit

/// Окно с кодом сопряжения: телефон сканирует QR один раз.
final class PairingWindowController: NSWindowController {
    private let code: String
    private let manualCode: String
    private let onRegenerate: () -> Void

    init(code: String, manualCode: String, onRegenerate: @escaping () -> Void) {
        self.code = code
        self.manualCode = manualCode
        self.onRegenerate = onRegenerate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Связь с iPhone"
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Отсканируй код в MLaud на iPhone")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let qr = NSImageView()
        qr.image = PhoneSyncController.qrImage(for: code)
        qr.imageScaling = .scaleProportionallyUpOrDown
        // Без интерполяции: сглаженный QR-код сканируется хуже, чем резкий.
        qr.layer?.magnificationFilter = .nearest

        let hint = NSTextField(wrappingLabelWithString:
            "Если камера недоступна, введи код вручную:")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let manual = NSTextField(labelWithString: manualCode)
        manual.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        manual.isSelectable = true

        let warning = NSTextField(wrappingLabelWithString:
            "Код — это ключ к записям. Показывай его только своему телефону.")
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor

        let regenerate = NSButton(title: "Сменить код…", target: self, action: #selector(regenerate))
        regenerate.bezelStyle = .rounded
        let close = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let buttons = NSStackView(views: [regenerate, NSView(), close])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [title, qr, hint, manual, warning, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            qr.widthAnchor.constraint(equalToConstant: 240),
            qr.heightAnchor.constraint(equalToConstant: 240),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func regenerate() {
        let alert = NSAlert()
        alert.messageText = "Сменить код сопряжения?"
        alert.informativeText = "Все уже связанные телефоны придётся связать заново."
        alert.addButton(withTitle: "Сменить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRegenerate()
        close()
    }

    @objc private func closeWindow() { close() }
}
