import AppKit

final class FloatingPanelController: NSObject {

    // MARK: - Constant
    // Change this value to replace the text that gets written to the clipboard and pasted.
    static let demoPasteText = "Hello world"

    private lazy var window: NSPanel = makePanel()
    private weak var contentView: PanelContentView?

    // MARK: - Public interface

    func show() {
        // orderFrontRegardless brings the window to front without activating our app.
        // makeKey makes it the key window so PanelContentView.keyDown fires.
        // Together with canBecomeKey = true (KeyablePanel) and .nonactivatingPanel,
        // the original app stays active the whole time — no NSApp.activate needed.
        window.orderFrontRegardless()
        window.makeKey()
        if let cv = contentView {
            window.makeFirstResponder(cv)
        }
    }

    /// Hide the panel without any clipboard/paste side-effect.  Called on Esc.
    func hide() {
        window.orderOut(nil)
    }

    /// Toggle: repeated ⌘⇧O presses show or hide the panel.
    func toggle() {
        window.isVisible ? hide() : show()
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
        pb.setString(Self.demoPasteText, forType: .string)
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
        panel.center()

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
        // combinedSessionState is more reliable than hidSystemState for targeting
        // the currently active app's text field.
        let src = CGEventSource(stateID: .combinedSessionState)
        // Suppress our own process from receiving this synthetic event.
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
        // cgSessionEventTap delivers to the currently active app's session.
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
