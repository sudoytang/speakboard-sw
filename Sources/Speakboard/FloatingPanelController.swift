import AppKit

final class FloatingPanelController: NSObject {

    // The text written to the clipboard and pasted on Enter.
    // nil means there is no valid text to paste (e.g. no speech detected);
    // pressing Enter will just close the panel in that case.
    var pasteText: String? = "Hello world"

    // Injected by AppDelegate after both objects are created.
    var sidecar: SidecarManager?

    // The transparent border around the blur view gives the system shadow room to
    // render and lets the window server see the rounded opaque shape, so hasShadow=true
    // produces a correctly rounded drop shadow without any manual CALayer shadow.
    private let shadowPad: CGFloat = 18
    private let cornerRad: CGFloat = 12

    private lazy var window: NSPanel = makePanel()
    private weak var contentView: PanelContentView?
    private let recorder = AudioRecorder()

    // MARK: - Public interface

    func show() {
        // Position on whichever screen the mouse is currently on.
        centerOnMouseScreen()

        window.orderFrontRegardless()
        window.invalidateShadow()   // recompute shadow from the composited alpha shape
        window.makeKey()
        if let cv = contentView {
            window.makeFirstResponder(cv)
        }
        // Reset label and paste text to default before each session.
        pasteText = "Hello world"
        contentView?.reset()
        // Start recording immediately; audio is discarded if Esc is pressed.
        recorder.startRecording { error in
            if let error { print("[recorder] \(error.localizedDescription)") }
        }
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let wf = window.frame
        let origin = NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2)
        window.setFrameOrigin(origin)
    }

    /// Hide the panel. Discards any in-progress recording.
    func hide() {
        _ = recorder.stopRecording()   // discard audio; no transcription
        window.orderOut(nil)
    }

    /// Toggle: repeated ⌘⇧O presses show or hide the panel.
    func toggle() {
        window.isVisible ? hide() : show()
    }

    // MARK: - Recording → transcription (called on A key)

    /// Stop recording, send audio to the backend, and call completion with the
    /// full Result on the main thread.  .success(text) = real transcript to paste;
    /// .failure = no valid text (caller should display the error message, not paste).
    func stopAndTranscribe(completion: @escaping (Result<String, Error>) -> Void) {
        guard let audioData = recorder.stopRecording() else {
            completion(.failure(SidecarError.notReady))
            return
        }
        guard let sidecar else {
            print("[panel] sidecar not set")
            completion(.failure(SidecarError.notReady))
            return
        }
        sidecar.transcribe(audioData: audioData) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Paste action  (called on Return / Insert button)

    /// 1. Write demoPasteText to the system clipboard.
    /// 2. Close the panel.
    /// 3. Simulate ⌘V to paste into the still-active original app.
    ///
    /// Step 3 requires Accessibility permission.
    /// If paste doesn't work: System Settings → Privacy & Security → Accessibility → add this app.
    func performPasteAction() {
        guard let text = pasteText else {
            hide()   // no valid text — just close, don't touch the clipboard
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hide()
        // The original app was never deactivated, so we paste immediately.
        simulateCmdV()
    }

    // MARK: - Private

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
        // hasShadow = true works correctly here: container is fully transparent and
        // blur is inset by shadowPad, so the window server sees only the rounded
        // opaque region and draws the system shadow to match it exactly.
        panel.hasShadow = true
        // Visually remove the title bar while keeping the underlying structure intact.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Built-in drag support: clicking the background drags the window.
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

    /// Resize the visible content area (blur view) to the given size and animate
    /// the window frame to match. Called from PanelContentView.
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

    private func simulateCmdV() {
        // CGEvent.post requires Accessibility permission.
        // On first run the system will show a permission dialog automatically.
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
