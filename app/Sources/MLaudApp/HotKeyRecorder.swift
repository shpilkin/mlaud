import AppKit
import MLaudCore

/// Поле «нажми сочетание». Кликнули — поле ждёт нажатия и запоминает его.
///
/// Своё, а не NSButton с меню: нужно перехватить нажатие ДО того, как система решит,
/// что это команда меню, поэтому переопределяем performKeyEquivalent — иначе ⌘-сочетания
/// уходили бы в меню приложения и до keyDown не доходили.
final class HotKeyRecorder: NSView {
    private(set) var combo: HotKey.Combo
    var onChange: ((HotKey.Combo) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")

    init(combo: HotKey.Combo) {
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                   : NSColor.controlBackgroundColor).setFill()
        dirtyRect.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: 5, yRadius: 5).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refresh()
        return true
    }

    /// Пока идёт запись, забираем себе любое сочетание, включая ⌘-шные.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard recording, capture(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(53) {  // Escape — отмена записи
            recording = false
            refresh()
            return true
        }
        let candidate = HotKey.Combo(
            keyCode: UInt32(event.keyCode),
            modifiers: HotKey.Combo.carbonModifiers(fromCocoa: event.modifierFlags.rawValue)
        )
        guard candidate.isValid else {
            NSSound.beep()  // без модификатора сочетание перехватывало бы обычный ввод
            return true
        }
        combo = candidate
        recording = false
        refresh()
        onChange?(candidate)
        return true
    }

    private func refresh() {
        label.stringValue = recording ? "нажми сочетание…" : combo.display
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        needsDisplay = true
    }
}
