import AppKit

// MARK: - Key-capture strategy
//
// The panel is made key via orderFrontRegardless() + makeKey() in FloatingPanelController.
// KeyablePanel.canBecomeKey returns true so makeKey() succeeds even with a non-standard
// style mask.  PanelContentView is set as first responder via panel.initialFirstResponder,
// and keyDown(with:) intercepts keys.
// No CGEventTap or Input Monitoring permission required.
//
// Key behaviour depends on PanelState:
//
//   recording(.shortPress)  ↩ → stop recording + transcribe    Esc → cancel + close
//   recording(.longPress)   ↩ → (ignored; release ⌘⇧O to stop) Esc → cancel + close
//   transcribing            ↩ → (ignored; wait for result)      Esc → close
//   result                  ↩ → paste & close                   Esc → close
//
// Dragging is handled by NSPanel.isMovableByWindowBackground = true.

final class PanelContentView: NSView {
    private weak var controller: FloatingPanelController?
    private let label      = NSTextField(labelWithString: "")
    private var hintLabel  = NSTextField(labelWithString: "")
    private var insertBtn  = NSButton()

    init(controller: FloatingPanelController) {
        self.controller = controller
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - State-driven UI updates

    /// Prepare the panel for a new recording session.
    func enterRecordingState(_ style: PanelState.RecordStyle) {
        updateLabel("")
        updateHintForState(.recording(style))
        insertBtn.isEnabled = false
    }

    /// Show the spinning-dots placeholder while waiting for the backend.
    func enterTranscribingState() {
        updateLabel("…")
        updateHintForState(.transcribing)
        insertBtn.isEnabled = false
    }

    /// Display the final transcript or error message.
    func enterResultState(text: String, pasteable: Bool) {
        updateLabel(text)
        updateHintForState(.result)
        insertBtn.isEnabled = pasteable
    }

    /// Update only the hint label (called when the hold threshold is reached).
    func updateHintForState(_ state: PanelState) {
        switch state {
        case .recording(.shortPress):
            hintLabel.stringValue = "↩  stop recording     Esc  cancel"
        case .recording(.longPress):
            hintLabel.stringValue = "release ⌘⇧O  to stop     Esc  cancel"
        case .transcribing:
            hintLabel.stringValue = "Transcribing…"
        case .result:
            hintLabel.stringValue = (controller?.pasteText != nil)
                ? "↩  paste & close     Esc  close"
                : "Esc  close"
        case .idle:
            hintLabel.stringValue = ""
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            guard let state = controller?.state else { return }
            switch state {
            case .recording(.shortPress):
                controller?.startTranscription()
            case .result:
                controller?.performPasteAction()
            default:
                break   // long-press recording and transcribing: ignore Enter
            }
        case 53: // Escape
            controller?.hide()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Label + window resize

    private let hPad: CGFloat     = 96    // total horizontal padding (48 pt each side)
    private let maxWidth: CGFloat  = 640
    private let minWidth: CGFloat  = 260
    // Vertical space consumed by everything except the label:
    //   top pad (20) + label-hint gap (8) + hint (~17) + hint-btn gap (8) + button (~28) + bottom pad (16)
    private let vOverhead: CGFloat = 110

    private func updateLabel(_ text: String) {
        label.stringValue = text

        let font = label.font ?? .systemFont(ofSize: 28, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        // Ideal content width: single-line measurement capped at maxWidth.
        let singleLineW = ceil((text as NSString).size(withAttributes: attrs).width) + hPad
        let newWidth    = max(minWidth, min(maxWidth, singleLineW))

        // Measure the text height at that width (handles both 1- and N-line text).
        let textAreaW = newWidth - hPad
        let measured  = (text as NSString).boundingRect(
            with: NSSize(width: textAreaW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let newHeight = max(130, ceil(measured.height) + vOverhead)

        // Tell the label its wrapping width so Auto Layout agrees with the measurement.
        label.preferredMaxLayoutWidth = textAreaW

        // Delegate window resize to the controller (adds shadow padding).
        controller?.resizeContent(toWidth: newWidth, height: newHeight)
    }

    // MARK: - Layout

    private func setupUI() {
        label.stringValue = ""
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.stringValue = "↩  stop recording     Esc  cancel"
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        insertBtn = NSButton(title: "Insert", target: self, action: #selector(insertTapped))
        insertBtn.bezelStyle = .rounded
        insertBtn.isEnabled = false
        insertBtn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(hintLabel)
        addSubview(insertBtn)

        // Top-down layout so the window height can grow with the label.
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad / 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(hPad / 2)),

            hintLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            insertBtn.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
            insertBtn.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @objc private func insertTapped() {
        controller?.performPasteAction()
    }
}
