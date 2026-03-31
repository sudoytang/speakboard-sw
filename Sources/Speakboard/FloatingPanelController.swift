import AppKit

// MARK: - State

enum PanelState {
    enum RecordStyle { case shortPress, longPress }
    case idle
    case recording(RecordStyle)  // shortPress: Enter stops; longPress: key release stops
    case transcribing            // awaiting backend response
    case result                  // transcript (or error message) ready to paste / dismiss
}

// MARK: - Controller

final class FloatingPanelController: NSObject {

    // Text written to the clipboard on Enter.  nil means no valid text to paste.
    var pasteText: String? = nil

    // Injected by AppDelegate after both objects are created.
    var sidecar: SidecarManager?

    // Exposed read-only so PanelContentView can inspect it in keyDown.
    private(set) var state: PanelState = .idle

    // Transparent border around the blur view that gives the system shadow room to
    // render and lets the window server see the rounded opaque shape.
    private let shadowPad: CGFloat = 18
    private let cornerRad: CGFloat = 12

    // A key held longer than this becomes a "long press": release ends recording.
    // A shorter press becomes a "short press": Enter ends recording.
    private let holdThreshold: TimeInterval = 0.5

    private lazy var window: NSPanel = makePanel()
    private weak var contentView: PanelContentView?
    private let recorder = AudioRecorder()

    private var pressTime: Date?
    private var holdWorkItem: DispatchWorkItem?

    // MARK: - Hotkey entry points

    /// Called on hotkey key-down.
    func hotkeyPressed() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        pressTime = Date()

        // Discard any in-flight recording from a previous session.
        _ = recorder.stopRecording()

        if window.isVisible {
            centerOnMouseScreen()
        } else {
            showWindow()
        }

        pasteText = nil
        state = .recording(.shortPress)
        contentView?.enterRecordingState(.shortPress)

        recorder.startRecording { error in
            if let error { print("[recorder] \(error.localizedDescription)") }
        }

        // After the hold threshold, upgrade to long-press mode if the recorder is running.
        let item = DispatchWorkItem { [weak self] in self?.onHoldThresholdReached() }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: item)
    }

    /// Called on hotkey key-up.
    func hotkeyReleased() {
        holdWorkItem?.cancel()
        holdWorkItem = nil

        guard case .recording(let style) = state else { return }

        switch style {
        case .longPress:
            // Key was held past the threshold: release ends recording.
            startTranscription()
        case .shortPress:
            // Released before the threshold; stay in recording mode.
            // The user will press Enter to stop recording.
            break
        }
    }

    // MARK: - Transcription

    /// Stop the recorder and send captured audio to the backend.
    /// Entry points: Enter key (short press) and hotkey release (long press).
    func startTranscription() {
        guard case .recording = state else { return }

        state = .transcribing
        contentView?.enterTranscribingState()

        guard let audioData = recorder.stopRecording() else {
            finishResult(text: nil, errorMessage: "No audio was captured.")
            return
        }
        guard let sidecar else {
            finishResult(text: nil, errorMessage: "Backend not connected.")
            return
        }

        sidecar.transcribe(audioData: audioData) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .transcribing = self.state else { return }
                switch result {
                case .success(let text):
                    self.finishResult(text: text, errorMessage: nil)
                case .failure(let error):
                    let msg = (error as? SidecarError)?.errorDescription ?? "Transcription failed."
                    self.finishResult(text: nil, errorMessage: msg)
                }
            }
        }
    }

    // MARK: - Paste

    /// Write pasteText to the clipboard and simulate ⌘V.
    /// If pasteText is nil, just close the panel.
    func performPasteAction() {
        guard case .result = state else { return }
        guard let text = pasteText else { hide(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hide()
        simulateCmdV()
    }

    // MARK: - Show / hide

    func hide() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        _ = recorder.stopRecording()
        state = .idle
        window.orderOut(nil)
    }

    func toggle() {
        window.isVisible ? hide() : hotkeyPressed()
    }

    // MARK: - Window resize (called from PanelContentView.updateLabel)

    /// Resize the visible content area (blur view) to the given size and animate
    /// the window frame to match.
    func resizeContent(toWidth contentW: CGFloat, height contentH: CGFloat) {
        let winW = contentW + 2 * shadowPad
        let winH = contentH + 2 * shadowPad

        let cur = window.frame
        guard abs(cur.width - winW) > 1 || abs(cur.height - winH) > 1 else { return }

        let newOriginX = cur.midX - winW / 2
        let newOriginY = cur.midY - winH / 2
        let newFrame = NSRect(x: newOriginX, y: newOriginY, width: winW, height: winH)

        if window.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: false)
        }
    }

    // MARK: - Private helpers

    private func onHoldThresholdReached() {
        guard case .recording(.shortPress) = state else { return }
        if recorder.isRecording {
            state = .recording(.longPress)
            contentView?.enterRecordingState(.longPress)
        }
        // If the recorder has not started yet (mic permission still pending),
        // stay in shortPress mode so the user can press Enter to finish.
    }

    private func finishResult(text: String?, errorMessage: String?) {
        state = .result
        pasteText = text
        if let text {
            contentView?.enterResultState(text: text, pasteable: true)
        } else {
            contentView?.enterResultState(text: errorMessage ?? "Transcription failed.", pasteable: false)
        }
    }

    private func showWindow() {
        centerOnMouseScreen()
        window.orderFrontRegardless()
        window.invalidateShadow()
        window.makeKey()
        if let cv = contentView { window.makeFirstResponder(cv) }
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let wf = window.frame
        let origin = NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2)
        window.setFrameOrigin(origin)
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let contentW: CGFloat = 340
        let contentH: CGFloat = 130
        let totalW = contentW + 2 * shadowPad
        let totalH = contentH + 2 * shadowPad

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: totalW, height: totalH),
            // .fullSizeContentView keeps the titled-window structure so that
            // canBecomeKey works correctly; the title bar is hidden visually below.
            // .nonactivatingPanel ensures showing the panel does not steal app activation.
            styleMask: [.fullSizeContentView, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // hasShadow = true works here: the container is fully transparent and the
        // blur view is inset by shadowPad, so the window server sees only the
        // rounded opaque region and draws the system shadow to match it exactly.
        panel.hasShadow = true
        // Visually remove the title bar while keeping the underlying structure intact.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true

        // Transparent container fills the full window frame (including shadow padding).
        // Its transparency lets the window server see only the inset blur view as
        // the opaque region, so the system drop shadow follows the rounded shape.
        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        // NSVisualEffectView clipped to rounded corners, inset from the window edge
        // by shadowPad so the shadow has room to render within the window bounds.
        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRad
        blur.layer?.masksToBounds = true
        container.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: shadowPad),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -shadowPad),
            blur.topAnchor.constraint(equalTo: container.topAnchor, constant: shadowPad),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -shadowPad),
        ])

        let cv = PanelContentView(controller: self)
        cv.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            cv.topAnchor.constraint(equalTo: blur.topAnchor),
            cv.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        contentView = cv
        panel.contentView = container
        panel.initialFirstResponder = cv
        return panel
    }

    private func simulateCmdV() {
        // CGEvent.post requires Accessibility permission.
        // On first run the system will show a permission dialog automatically.
        // If paste does not work: System Settings → Privacy & Security → Accessibility → add this app.
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let dn = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        let cmdFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        dn?.flags = cmdFlag
        up?.flags = cmdFlag
        dn?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - NSPanel subclass

// NSPanel with a borderless/fullSizeContentView style mask returns false for
// canBecomeKey by default, which silently prevents makeKey from working and
// causes unhandled key events (alert beep).  This subclass overrides it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
