import AppKit

// MARK: - Key-capture strategy
//
// The panel is made key via orderFrontRegardless() + makeKey() in FloatingPanelController.show().
// KeyablePanel.canBecomeKey returns true, so makeKey() succeeds even with a non-standard style mask.
// PanelContentView is then set as first responder, and keyDown(with:) intercepts the keys.
// No CGEventTap, no Input Monitoring permission required.
//
//   keyCode 36  →  Return / Enter  →  clipboard write + ⌘V paste
//   keyCode 53  →  Escape          →  close panel only
//
// Dragging is handled by NSPanel.isMovableByWindowBackground = true — no mouseDown override needed.

final class PanelContentView: NSView {
    private weak var controller: FloatingPanelController?

    init(controller: FloatingPanelController) {
        self.controller = controller
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            controller?.performPasteAction()
        case 53: // Escape
            controller?.hide()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Layout

    private func setupUI() {
        let label = NSTextField(labelWithString: FloatingPanelController.demoPasteText)
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↩  paste & close     Esc  close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        let btn = NSButton(title: "Insert", target: self, action: #selector(insertTapped))
        btn.bezelStyle = .rounded
        btn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(hint)
        addSubview(btn)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),

            hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),

            btn.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            btn.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @objc private func insertTapped() {
        controller?.performPasteAction()
    }
}
