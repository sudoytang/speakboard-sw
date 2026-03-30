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
        updateLabel(controller?.pasteText ?? "Hello world")   // pasteText is "Hello world" at show() time
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            controller?.performPasteAction()
        case 53: // Escape
            controller?.hide()
        case 0:  // A — stop recording, send to backend, update label with transcript
            updateLabel("…")
            controller?.stopAndTranscribe { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    // Real transcription: store for pasting and display it.
                    self.controller?.pasteText = text
                    self.updateLabel(text)
                case .failure(let error):
                    // No usable text: show a status message but block pasting.
                    self.controller?.pasteText = nil
                    self.updateLabel((error as? SidecarError)?.errorDescription ?? "（转录失败）")
                }
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Label + window resize

    private let hPad: CGFloat  = 96    // total horizontal padding (48 pt each side)
    private let maxWidth: CGFloat = 640
    private let minWidth: CGFloat = 260
    // Space taken up by everything except the label:
    //   top pad(20) + label-hint gap(8) + hint(~17) + hint-btn gap(8) + button(~28) + bottom pad(16) ≈ 97
    private let vOverhead: CGFloat = 110

    /// Update the label text and ask the controller to resize the window to fit.
    /// newWidth / newHeight here are CONTENT sizes (blur view), not window frame sizes.
    /// FloatingPanelController.resizeContent(toWidth:height:) adds shadow padding.
    private func updateLabel(_ text: String) {
        label.stringValue = text

        let font = label.font ?? .systemFont(ofSize: 28, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        // 1. Determine the ideal content width (single-line capped at maxWidth).
        let singleLineW = ceil((text as NSString).size(withAttributes: attrs).width) + hPad
        let newWidth = max(minWidth, min(maxWidth, singleLineW))

        // 2. Measure the text height at that content width (handles 1- and N-line text).
        let textAreaW = newWidth - hPad
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textAreaW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let newHeight = max(130, ceil(measured.height) + vOverhead)

        // 3. Tell the label its wrapping width so Auto Layout agrees with our measurement.
        label.preferredMaxLayoutWidth = textAreaW

        // 4. Delegate window resize + shadow update to the controller.
        controller?.resizeContent(toWidth: newWidth, height: newHeight)
    }

    // MARK: - Layout

    private func setupUI() {
        label.stringValue = controller?.pasteText ?? "Hello world"
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0          // allow wrapping
        label.lineBreakMode = .byWordWrapping
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

        // Top-down layout so the window height can grow with the label.
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad / 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(hPad / 2)),

            hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),

            btn.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            btn.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @objc private func insertTapped() {
        controller?.performPasteAction()
    }
}
