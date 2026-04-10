import AppKit

/// Draws a coloured ring around the frontmost window while inline dictation is active,
/// so the user can clearly see which window will receive the transcribed text.
///
/// The overlay is completely transparent to mouse events and never steals focus.
final class HighlightOverlay {

    private var panel: NSPanel?

    // MARK: - Public

    func show() {
        guard let frame = focusedWindowFrame() else { return }
        let p = makePanel(frame: frame)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    // MARK: - Panel construction

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.level             = .floating
        p.backgroundColor   = .clear
        p.isOpaque          = false
        p.hasShadow         = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = HighlightView(frame: NSRect(origin: .zero, size: frame.size))
        return p
    }

    // MARK: - AX window lookup

    private func focusedWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Don't highlight our own panel.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, "AXFocusedWindow" as CFString, &windowRef
        ) == .success, let windowRef else { return nil }

        var frameVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            // swiftlint:disable:next force_cast
            windowRef as! AXUIElement, "AXFrame" as CFString, &frameVal
        ) == .success, let frameVal else { return nil }

        var axRect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(frameVal as! AXValue, .cgRect, &axRect) else { return nil }

        // AX uses a top-left origin (Y increases downward) relative to the primary
        // screen.  AppKit uses a bottom-left origin (Y increases upward).
        let mainH = NSScreen.screens[0].frame.height
        return NSRect(
            x: axRect.origin.x,
            y: mainH - axRect.origin.y - axRect.height,
            width:  axRect.width,
            height: axRect.height
        )
    }
}

// MARK: - Highlight ring view

private final class HighlightView: NSView {

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat  = 1.5
        let radius: CGFloat = 12
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = 3.5
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}
