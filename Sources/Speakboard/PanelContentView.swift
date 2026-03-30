import AppKit

// MARK: - Key-capture strategy
//
// The panel is made key via orderFrontRegardless() + makeKey() in FloatingPanelController.show().
// KeyablePanel.canBecomeKey returns true, so makeKey() succeeds even with a non-standard style mask.
// PanelContentView is then set as first responder via panel.initialFirstResponder,
// and keyDown(with:) intercepts the keys.
// No CGEventTap, no Input Monitoring permission required.
//
//   keyCode 36  →  Return / Enter  →  clipboard write + ⌘V paste
//   keyCode 53  →  Escape          →  close panel only
//
// Dragging is handled by NSPanel.isMovableByWindowBackground = true — no mouseDown override needed.

final class PanelContentView: NSView {
    private weak var controller: FloatingPanelController?
    private let label = NSTextField(labelWithString: "")   // kept as instance var so A key can update it

    init(controller: FloatingPanelController) {
        self.controller = controller
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    func reset() {
        updateLabel(controller?.pasteText ?? "Hello world")
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            controller?.performPasteAction()
        case 53: // Escape
            controller?.hide()
        case 0:  // A — stop recording, send to backend, update label with transcript
            updateLabel("…")
            controller?.stopAndTranscribe { [weak self] text in
                guard let self else { return }
                let result = text ?? "（transcription failed）"
                self.controller?.pasteText = result
                self.updateLabel(result)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Label + window resize

    /// Update the label text and animate the window width to fit.
    private func updateLabel(_ text: String) {
        label.stringValue = text

        guard let w = window else { return }

        // Measure how wide the label wants to be at the current font.
        let attrs: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        let newWidth = max(260, min(700, ceil(textWidth) + 96))  // 48 pt padding each side

        let cur = w.frame
        guard abs(cur.width - newWidth) > 1 else { return }   // skip if already the right size

        // Animate width change while keeping the window horizontally centred.
        let newOriginX = cur.midX - newWidth / 2
        let newFrame = NSRect(x: newOriginX, y: cur.minY, width: newWidth, height: cur.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Layout

    private func setupUI() {
        label.stringValue = controller?.pasteText ?? "Hello world"
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
