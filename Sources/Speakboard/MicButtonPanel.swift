import AppKit

// A small always-on-top floating panel containing a mic button.
//
// The panel uses .nonactivatingPanel so clicking it NEVER steals keyboard focus
// or application activation from the frontmost app — the cursor stays where it is.
//
// IMPLEMENTATION NOTE: The button is an NSButton subclass (not NSView) because
// AppKit's event routing to NSButton inside a .nonactivatingPanel is more reliable
// than routing to a plain NSView.

final class MicButtonPanel {

    /// Fired on mouseDown (used by .hold mode).
    var onPress:   (() -> Void)?
    /// Fired on mouseUp (used by .hold mode).
    var onRelease: (() -> Void)?
    /// Fired on a tap (mouseUp with no significant drag). Used by .toggle / .autoStop modes.
    var onTap:     (() -> Void)?

    /// Current mode — used to build the right-click context menu.
    var currentMode: DictationMode = DictationMode.load() {
        didSet { micButton?.currentMode = currentMode }
    }
    /// Called when user picks a new mode from the context menu.
    var onModeChange: ((DictationMode) -> Void)?

    private lazy var nsPanel: NSPanel = makePanel()
    private weak var micButton: MicHoldButton?

    // MARK: - Public

    func show() { nsPanel.orderFrontRegardless() }
    func hide() { nsPanel.orderOut(nil) }

    func setRecording(_ recording: Bool) {
        micButton?.isRecordingActive = recording
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let size: CGFloat = 56

        let panel = MicPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        panel.level            = .floating
        panel.isFloatingPanel  = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate    = false
        panel.backgroundColor  = .clear
        panel.isOpaque         = false
        panel.hasShadow        = true
        panel.titleVisibility  = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: sf.maxX - size - 24, y: sf.minY + 24))
        }
        panel.center()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.autoresizingMask = [.width, .height]

        let btn = MicHoldButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        btn.currentMode = currentMode
        btn.onPress   = { [weak self] in self?.onPress?() }
        btn.onRelease = { [weak self] in self?.onRelease?() }
        btn.onTap     = { [weak self] in self?.onTap?() }
        btn.onModeChange = { [weak self] mode in
            self?.currentMode = mode
            self?.onModeChange?(mode)
        }
        btn.autoresizingMask = [.width, .height]
        micButton = btn

        container.addSubview(btn)
        panel.contentView = container
        return panel
    }
}

// MARK: - Panel subclass

private final class MicPanel: NSPanel {
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Mic button (NSButton subclass)

private final class MicHoldButton: NSButton {

    var onPress:      (() -> Void)?
    var onRelease:    (() -> Void)?
    /// Fired when mouse up happens without a significant drag.
    var onTap:        (() -> Void)?
    var onModeChange: ((DictationMode) -> Void)?

    var currentMode: DictationMode = .hold

    var isRecordingActive = false {
        didSet { needsDisplay = true }
    }

    // Drag tracking
    private var dragStartScreenLoc: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var hasDragged = false
    private let dragThreshold: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered  = false
        bezelStyle  = .rounded
        title       = ""
        wantsLayer  = true
        layer?.cornerRadius = frame.width / 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 4
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let circle = NSBezierPath(ovalIn: rect)
        (isRecordingActive ? NSColor.systemRed : NSColor(white: 0.95, alpha: 0.9)).setFill()
        circle.fill()

        NSColor(white: 0, alpha: 0.10).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        let pointSize: CGFloat = 18
        let cfg  = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let name = isRecordingActive ? "mic.fill" : "mic"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus()
            (isRecordingActive ? NSColor.white : NSColor.labelColor).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let destRect = NSRect(
                x: (bounds.width  - tinted.size.width)  / 2,
                y: (bounds.height - tinted.size.height) / 2,
                width:  tinted.size.width,
                height: tinted.size.height
            )
            tinted.draw(in: destRect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: - Mouse tracking

    override func mouseDown(with event: NSEvent) {
        dragStartScreenLoc    = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        hasDragged = false
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startScreen = dragStartScreenLoc,
              let startOrigin = dragStartWindowOrigin else { return }
        let cur = NSEvent.mouseLocation
        let dx  = cur.x - startScreen.x
        let dy  = cur.y - startScreen.y
        if hypot(dx, dy) > dragThreshold { hasDragged = true }
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = hasDragged
        dragStartScreenLoc    = nil
        dragStartWindowOrigin = nil
        hasDragged = false

        if !wasDrag { onTap?() }
        onRelease?()
    }

    // MARK: - Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "")

        // — Hold to Speak —
        let holdItem = menuItem(.hold)
        menu.addItem(holdItem)

        // — Click to Start (submenu) —
        let clickModes: [DictationMode] = [
            .toggle,
            .autoStop(silenceDelay: 1.0),
            .autoStop(silenceDelay: 2.0),
        ]
        let clickParent = NSMenuItem(title: "Click to Start", action: nil, keyEquivalent: "")
        let isClickMode = clickModes.contains(currentMode)
        if isClickMode { clickParent.state = .on }

        let sub = NSMenu(title: "")
        for m in clickModes { sub.addItem(menuItem(m)) }
        clickParent.submenu = sub
        menu.addItem(clickParent)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(_ mode: DictationMode) -> NSMenuItem {
        let item = NSMenuItem(title: mode.menuTitle,
                              action: #selector(modeSelected(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = ModeBox(mode)
        if mode == currentMode { item.state = .on }
        return item
    }

    @objc private func modeSelected(_ item: NSMenuItem) {
        guard let box = item.representedObject as? ModeBox else { return }
        currentMode = box.mode
        onModeChange?(box.mode)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// Simple wrapper so DictationMode (not an NSObject) can be stored as representedObject.
private final class ModeBox: NSObject {
    let mode: DictationMode
    init(_ mode: DictationMode) { self.mode = mode }
}
