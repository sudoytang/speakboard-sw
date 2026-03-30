import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var capsule:   CapsuleWindowController!
    private var sidecar:   SidecarManager!
    private var recorder:  AudioRecorder!
    private var hotkey:    GlobalHotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        capsule   = CapsuleWindowController()
        statusBar = StatusBarController()
        sidecar   = SidecarManager()
        recorder  = AudioRecorder()

        // Forward real-time RMS from the audio engine to the waveform view.
        recorder.onRMSUpdate = { [weak self] rms in
            self?.capsule.updateRMS(rms)
        }

        // ⌘⇧O held   → start recording + show capsule
        // ⌘⇧O release → stop recording, transcribe, update capsule
        hotkey = GlobalHotkeyManager(
            onPress:   { [weak self] in self?.handlePress() },
            onRelease: { [weak self] in self?.handleRelease() }
        )

        // Start the Python sidecar in the background.
        // The backend loads the Whisper model (~5–30 s); we poll /health until ready.
        sidecar.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.stop()
    }

    // MARK: - Hotkey handlers

    private func handlePress() {
        capsule.transition(to: .recording)
        recorder.startRecording { [weak self] error in
            if let error {
                print("[app] recording failed: \(error.localizedDescription)")
                self?.capsule.transition(to: .error)
            }
        }
    }

    private func handleRelease() {
        guard let audioData = recorder.stopRecording() else {
            capsule.transition(to: .error)
            return
        }

        capsule.transition(to: .processing)

        sidecar.transcribe(audioData: audioData) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    // Write result to the system clipboard as well.
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    self?.capsule.transition(to: .result(text))
                case .failure(let error):
                    print("[app] transcription failed: \(error.localizedDescription)")
                    self?.capsule.transition(to: .error)
                }
            }
        }
    }
}
