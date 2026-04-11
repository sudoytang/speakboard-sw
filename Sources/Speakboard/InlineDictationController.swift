import AppKit

// InlineDictationController — "hold-to-dictate" mode that types transcription
// text directly at the cursor position in the frontmost app.
//
// Supports three DictationModes (see DictationMode.swift):
//   .hold      — hold button → record, release → stop  (default)
//   .toggle    — first click starts, second click stops
//   .autoStop  — click to start; silence timer calls endDictation() automatically
//
// While active the controller temporarily replaces FloatingPanelController's
// callbacks on the shared SidecarManager. On finish/cancel it restores the
// panel callbacks via panel.reattachSidecarCallbacks().
//
// THREADING: all public methods and callbacks must be called on the main thread.

final class InlineDictationController {

    private let settings: SettingsStore

    // Injected by AppDelegate.
    weak var sidecar: SidecarManager?
    weak var panel: FloatingPanelController?

    /// Fired when active state changes (true = recording, false = idle/finished).
    var onStateChange: ((Bool) -> Void)?

    /// Current trigger mode. Persisted to UserDefaults automatically on set.
    var mode: DictationMode = DictationMode.load() {
        didSet { mode.save() }
    }

    private(set) var isActive = false

    private let recorder  = AudioRecorder()
    private let highlight = HighlightOverlay()
    /// Number of grapheme clusters currently typed at cursor (pending partial).
    private var insertedCount = 0
    /// Silence auto-stop timer (only used in .autoStop mode).
    private var silenceTimer: DispatchWorkItem?

    // MARK: - Init

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        recorder.onChunk = { [weak self] data in
            self?.sidecar?.sendAudioChunk(data)
        }
        applySettings()
    }

    // MARK: - Public

    var isReady: Bool { sidecar?.isReady == true }

    func applySettings() {
        if settings.inlineWarmUpEnabled {
            recorder.warmUp()
        } else if !isActive {
            recorder.coolDown()
        }
    }

    // MARK: Button event handlers (called by AppDelegate)

    /// Called on mouseDown. Starts recording only in .hold mode.
    func handlePress() {
        if case .hold = mode { beginDictation() }
    }

    /// Called on mouseUp. Stops recording only in .hold mode.
    func handleRelease() {
        if case .hold = mode { endDictation() }
    }

    /// Called on a tap (mouseUp without drag). Handles .toggle and .autoStop.
    func handleTap() {
        switch mode {
        case .hold:
            break   // handled entirely by handlePress/handleRelease
        case .toggle:
            if isActive { endDictation() } else { beginDictation() }
        case .autoStop:
            if isActive { endDictation() } else { beginDictation() }
        }
    }

    // MARK: Core dictation lifecycle

    /// Start a dictation session. No-op if already active or sidecar not ready.
    func beginDictation() {
        guard !isActive else { return }
        guard let sidecar, sidecar.isReady else {
            print("[inline] sidecar not ready — skipping")
            return
        }
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        isActive = true
        insertedCount = 0
        highlight.show()

        // Take over SidecarManager callbacks for inline mode.
        sidecar.onPartial = { [weak self] text in
            self?.updateInline(text)
        }
        sidecar.onGoldUpdate = { [weak self] text in
            self?.updateInline(text)
        }
        sidecar.onFinalResult = { [weak self] text in
            self?.finalize(text)
        }

        sidecar.beginSession()
        recorder.startRecording { error in
            if let error { print("[inline] recorder error: \(error.localizedDescription)") }
        }
        onStateChange?(true)
        // Silence timer starts only after first speech is detected (in updateInline).
    }

    /// Stop recording and wait for the final transcription.
    func endDictation() {
        guard isActive else { return }
        cancelSilenceTimer()
        recorder.stopRecording()
        if !settings.inlineWarmUpEnabled {
            recorder.coolDown()
        }
        sidecar?.sendStop()
        // finalize() is called asynchronously via onFinalResult.
    }

    /// Cancel without producing a result; removes any partial text already typed.
    func cancel() {
        guard isActive else { return }
        cancelSilenceTimer()
        isActive = false
        recorder.stopRecording()
        if !settings.inlineWarmUpEnabled {
            recorder.coolDown()
        }
        sidecar?.cancelSession()
        if insertedCount > 0 {
            sendBackspaces(insertedCount)
            insertedCount = 0
        }
        finish()
    }

    // MARK: - Private — silence timer

    private func resetSilenceTimer() {
        guard case .autoStop(let delay) = mode else { return }
        silenceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endDictation() }
        silenceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    // MARK: - Private — text update

    private func updateInline(_ newText: String) {
        guard isActive else { return }
        // Backend sent a speech update — reset the silence countdown.
        resetSilenceTimer()
        let newCount = newText.count   // grapheme clusters == visual cursor positions
        sendBackspaces(insertedCount)
        if newCount > 0 { typeString(newText) }
        insertedCount = newCount
    }

    private func finalize(_ text: String?) {
        cancelSilenceTimer()
        defer { if !isActive { panel?.reattachSidecarCallbacks() } }
        guard isActive else { return }
        isActive = false
        sendBackspaces(insertedCount)
        insertedCount = 0
        if let text, !text.isEmpty {
            typeString(text)
        }
        finish()
    }

    private func finish() {
        highlight.hide()
        onStateChange?(false)
        panel?.reattachSidecarCallbacks()
    }

    // MARK: - Private — CGEvent helpers

    /// Send `count` Delete (⌫) key events to the frontmost app.
    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let dn = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
            dn?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    /// Type `text` at the current cursor position using a single Unicode keyboard event.
    private func typeString(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        var utf16 = Array(text.utf16)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        dn?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        dn?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.post(tap: .cgSessionEventTap)
    }
}

