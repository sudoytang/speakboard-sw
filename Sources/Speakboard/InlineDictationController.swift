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
        highlight.show()
        print("[inline] beginDictation: setting up yolo callbacks (onPartial=nil, onGoldUpdate=nil, onCommit=set)")

        // Take over SidecarManager callbacks for yolo (append-only) mode.
        sidecar.onPartial = nil
        sidecar.onGoldUpdate = nil
        sidecar.onCommit = { [weak self] text in
            print("[inline] onCommit received: \"\(text)\"")
            self?.appendCommit(text)
        }
        sidecar.onFinalResult = { [weak self] text in
            print("[inline] onFinalResult received: \"\(text ?? "(nil)")\"")
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

    /// Cancel without producing a result. Already committed text stays in place
    /// (yolo mode is append-only — we cannot safely backspace committed text
    /// because the user may have switched windows).
    func cancel() {
        guard isActive else { return }
        cancelSilenceTimer()
        isActive = false
        recorder.stopRecording()
        if !settings.inlineWarmUpEnabled {
            recorder.coolDown()
        }
        sidecar?.cancelSession()
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

    // MARK: - Private — text update (yolo / append-only)

    /// Backend committed a completed utterance — just append it at the cursor.
    private func appendCommit(_ text: String) {
        guard isActive else { return }
        resetSilenceTimer()
        typeString(text)
    }

    /// Session ended. In yolo mode the backend flushes the last utterance as a
    /// final commit, so `text` here is the full accumulated session text. We
    /// don't need to retype it — individual commits already typed everything.
    private func finalize(_ text: String?) {
        cancelSilenceTimer()
        defer { if !isActive { panel?.reattachSidecarCallbacks() } }
        guard isActive else { return }
        isActive = false
        finish()
    }

    private func finish() {
        highlight.hide()
        onStateChange?(false)
        panel?.reattachSidecarCallbacks()
    }

    // MARK: - Private — CGEvent helpers

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

