import AppKit

// MARK: - CapsuleWindowController
//
// Manages the bottom-centre floating capsule window.
//
// Window spec:
//   • 56 pt tall, corner radius 28 pt (perfect pill)
//   • Dark frosted-glass background (NSVisualEffectView .hudWindow + .vibrantDark)
//   • Width adapts per state; re-centres on screen each time
//   • Level: .statusBar (floats above all normal windows)
//   • .nonactivatingPanel → never steals focus from the frontmost app
//
// Animations:
//   • Entry:     0.35 s spring (window slides up from 10 pt below + fades in)
//   • Width:     0.25 s ease-in-out (re-centres on screen)
//   • Exit:      0.22 s scale-down + fade (content view scales to 0.7, window fades out)
//   • Auto-dismiss after 3 s (result) or 2 s (error)

final class CapsuleWindowController: NSObject {

    // MARK: - Geometry

    private let capsuleH:     CGFloat = 56
    private let cornerRadius: CGFloat = 28
    private let bottomInset:  CGFloat = 36   // distance from visible screen bottom

    // Per-state widths
    private enum W {
        static let recording:  CGFloat = 120
        static let processing: CGFloat = 80
        static let error:      CGFloat = 80
        static func result(_ text: String) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            let w = (text as NSString).size(withAttributes: attrs).width
            return min(520, max(200, w + 56))
        }
    }

    // MARK: - Internals

    private lazy var window: NSPanel    = makeWindow()
    private var contentView: CapsuleContentView!   // set inside makeWindow()
    private var shadowShapeLayer: CAShapeLayer?    // updated on every width change
    private var dismissWork: DispatchWorkItem?

    // MARK: - Public interface

    func transition(to state: CapsuleState) {
        dismissWork?.cancel()
        dismissWork = nil

        let targetWidth = width(for: state)

        if window.isVisible {
            animateWidth(to: targetWidth)
        } else {
            appear(width: targetWidth)
        }

        contentView.setState(state)

        switch state {
        case .result: scheduleDismiss(after: 3.0)
        case .error:  scheduleDismiss(after: 2.0)
        default: break
        }
    }

    func updateRMS(_ rms: Float) {
        contentView.updateRMS(rms)
    }

    // MARK: - Window construction

    private func makeWindow() -> NSPanel {
        let initialW = W.recording

        // KeyablePanel overrides canBecomeKey → true, which is required for any
        // NSPanel with a non-standard styleMask to accept makeKey() and therefore
        // receive keyboard events (Enter / Esc) via the normal responder chain.
        //
        // .fullSizeContentView keeps the underlying title-bar structure intact
        // (so canBecomeKey works), while the title bar is hidden visually below.
        // .nonactivatingPanel ensures the capsule never steals app activation.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initialW, height: capsuleH),
            styleMask:   [.fullSizeContentView, .closable, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level              = .statusBar
        panel.isFloatingPanel    = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate  = false
        panel.backgroundColor    = .clear
        panel.isOpaque           = false
        panel.hasShadow          = false
        panel.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        // Visually remove the title bar while keeping the structure that canBecomeKey needs.
        panel.titleVisibility             = .hidden
        panel.titlebarAppearsTransparent  = true
        panel.titlebarSeparatorStyle      = .none
        panel.standardWindowButton(.closeButton)?.isHidden    = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden     = true

        // ── Container (transparent; lets CALayer shadow extend beyond blur view) ──
        let container = NSView(frame: NSRect(x: 0, y: 0, width: initialW, height: capsuleH))
        container.wantsLayer             = true
        container.autoresizingMask       = [.width, .height]

        // Shadow layer (capsule-shaped, no fill; drawn below the blur view)
        let shadow = CAShapeLayer()
        shadow.fillColor   = NSColor.clear.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.50
        shadow.shadowRadius  = 14
        shadow.shadowOffset  = CGSize(width: 0, height: -3)
        let initialBounds = CGRect(x: 0, y: 0, width: initialW, height: capsuleH)
        shadow.path       = capsulePath(in: initialBounds)
        shadow.shadowPath = shadow.path
        container.layer?.addSublayer(shadow)
        shadowShapeLayer = shadow

        // Blur view (the visible capsule background)
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: initialW, height: capsuleH))
        blur.material      = .hudWindow
        blur.blendingMode  = .behindWindow
        blur.state         = .active
        blur.appearance    = NSAppearance(named: .vibrantDark)
        blur.wantsLayer    = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.autoresizingMask     = [.width, .height]
        container.addSubview(blur)

        // Content view (the UI)
        let cv = CapsuleContentView(frame: NSRect(x: 0, y: 0, width: initialW, height: capsuleH))
        cv.autoresizingMask = [.width, .height]
        blur.addSubview(cv)
        contentView = cv

        // Wire key-event callbacks.
        cv.onEsc   = { [weak self] in self?.dismissNow() }
        cv.onEnter = { [weak self] in self?.pasteAndDismiss() }

        panel.contentView = container
        return panel
    }

    // MARK: - Appearance / disappearance

    private func appear(width: CGFloat) {
        let finalFrame = targetFrame(width: width)
        var startFrame = finalFrame
        startFrame.origin.y -= 10

        window.setFrame(startFrame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        // makeKey() lets the panel receive keyboard events without activating
        // the app, so the previous app stays frontmost (paste targets it).
        window.makeKey()
        window.makeFirstResponder(contentView)
        updateShadow(width: width)

        // Spring-like entry: slides up + fades in (0.35 s).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.05)
            window.animator().setFrame(finalFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    // Called from key-event closures; also cancels the auto-dismiss timer.
    private func dismissNow() {
        dismissWork?.cancel()
        dismissWork = nil
        dismiss()
    }

    // Enter in result state: paste the text already on the clipboard, then dismiss.
    // The previous app is still frontmost (never deactivated), so ⌘V lands there.
    private func pasteAndDismiss() {
        dismissNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
            let dn = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            dn?.flags = .maskCommand
            up?.flags = .maskCommand
            dn?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    private func dismiss() {
        guard window.isVisible else { return }

        // Scale the content layer down while fading out (0.22 s).
        if let layer = (window.contentView?.subviews.last)?.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.toValue  = 0.72
            scale.duration = 0.22
            scale.timingFunction  = CAMediaTimingFunction(name: .easeIn)
            scale.fillMode        = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "exit-scale")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration       = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }) { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1
            if let layer = (self?.window.contentView?.subviews.last)?.layer {
                layer.removeAllAnimations()
                layer.transform = CATransform3DIdentity
            }
        }
    }

    // MARK: - Width animation

    private func animateWidth(to newWidth: CGFloat) {
        let cur = window.frame
        var newFrame = cur
        newFrame.size.width  = newWidth
        newFrame.origin.x    = cur.midX - newWidth / 2

        updateShadow(width: newWidth)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Helpers

    private func width(for state: CapsuleState) -> CGFloat {
        switch state {
        case .recording:        return W.recording
        case .processing:       return W.processing
        case .result(let text): return W.result(text)
        case .error:            return W.error
        }
    }

    private func targetFrame(width: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        return NSRect(x: sf.midX - width / 2, y: sf.minY + bottomInset,
                      width: width, height: capsuleH)
    }

    private func scheduleDismiss(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func updateShadow(width: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: capsuleH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowShapeLayer?.frame      = bounds
        shadowShapeLayer?.path       = capsulePath(in: bounds)
        shadowShapeLayer?.shadowPath = shadowShapeLayer?.path
        CATransaction.commit()
    }

    private func capsulePath(in rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect,
               cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
               transform: nil)
    }
}

// MARK: - KeyablePanel

// NSPanel with a non-standard styleMask returns false for canBecomeKey by
// default, which means makeKey() has no effect and the panel never enters the
// responder chain.  Overriding to true restores normal key-event delivery.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
