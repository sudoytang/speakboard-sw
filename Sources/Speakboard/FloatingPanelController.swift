import AppKit

final class FloatingPanelController: NSObject {

    // The text written to the clipboard and pasted on Enter.
    // Updated by PanelContentView after a successful transcription.
    var pasteText = "Hello world"

    // Injected by AppDelegate after both objects are created.
    var sidecar: SidecarManager?

    private lazy var window: NSPanel = makePanel()
    private weak var contentView: PanelContentView?
    private let recorder = AudioRecorder()

    // MARK: - Public interface

    func show() {
        // Position on whichever screen the mouse is currently on.
        centerOnMouseScreen()

        window.orderFrontRegardless()
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

    /// Stop recording, send the audio to the backend, and call completion with
    /// the transcript text (or nil on failure).  Runs completion on the main thread.
    func stopAndTranscribe(completion: @escaping (String?) -> Void) {
        guard let audioData = recorder.stopRecording() else {
            completion(nil)
            return
        }
        guard let sidecar else {
            print("[panel] sidecar not set")
            completion(nil)
            return
        }
        sidecar.transcribe(audioData: audioData) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): completion(text)
                case .failure(let err):
                    print("[panel] transcription failed: \(err.localizedDescription)")
                    completion(nil)
                }
            }
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pasteText, forType: .string)
        hide()
        // The original app was never deactivated, so we paste immediately.
        simulateCmdV()
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
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

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

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
        panel.contentView = blur
        panel.initialFirstResponder = cv
        return panel
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
