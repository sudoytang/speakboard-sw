import Foundation

// Manages the Rust backend sidecar process and a persistent WebSocket connection to it.
//
// Connection lifecycle:
//   start() → launch process → connect after 2 s → receive "ready" → isReady = true
//   Per recording session: beginSession() → sendAudioChunk() × N → sendStop()
//   → server sends GoldReplace → onFinalResult called → WS closes → reconnect
//   On unexpected disconnect: retry up to maxReconnectAttempts, then restart process.

final class SidecarManager {

    // MARK: - Callbacks (set by FloatingPanelController before start())

    /// Called once the WebSocket connection is established and the server sends "ready".
    var onReady: (() -> Void)?
    /// Called with the latest provisional transcription text during recording.
    var onPartial: ((String) -> Void)?
    /// Called whenever an accurate gold-boundary transcription arrives mid-recording (accumulated).
    var onGoldUpdate: ((String) -> Void)?
    /// Called with the final accumulated transcription after sendStop(), or nil if nothing detected.
    var onFinalResult: ((String?) -> Void)?

    // MARK: - State

    private(set) var isReady = false

    // MARK: - Config

    private let settings: SettingsStore
    private var port: Int { settings.port }

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    // MARK: - Constants

    private let maxReconnectAttempts = 3

    // MARK: - Internal

    private var process: Process?
    private var wsTask: URLSessionWebSocketTask?
    private lazy var urlSession = URLSession(configuration: .default)

    private var shouldReconnect = true
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?

    // Per-session state
    private var sessionGoldText = ""
    private var sessionStopped = false
    private var finalResultDelivered = false
    // Ordered list of (id, text) for pending partials.
    // Same id → refinement of existing speech (replace in-place).
    // New id → new speech segment (append).
    // gold_replace clears this entirely.
    private var pendingPartials: [(id: String, text: String)] = []

    // MARK: - Lifecycle

    func start() {
        shouldReconnect = true
        do {
            try settings.writeConfigFile()
        } catch {
            print("[sidecar] failed to write config: \(error)")
        }
        startProcess()
    }

    /// Stop the backend, then start it again with the current settings.
    func restart() {
        stop()
        shouldReconnect = true
        do {
            try settings.writeConfigFile()
        } catch {
            print("[sidecar] failed to write config: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startProcess()
        }
    }

    func stop() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        isReady = false
    }

    // MARK: - Session control

    /// Reset per-session state before a new recording starts.
    func beginSession() {
        sessionGoldText = ""
        pendingPartials = []
        sessionStopped = false
        finalResultDelivered = false
    }

    /// Send raw PCM i16 LE audio chunk to the server. Safe to call from any thread.
    func sendAudioChunk(_ data: Data) {
        guard isReady, let task = wsTask else { return }
        task.send(.data(data)) { error in
            if let error { print("[sidecar] chunk send error: \(error)") }
        }
    }

    /// Signal the server to flush remaining audio and produce the final transcription.
    func sendStop() {
        sessionStopped = true
        sendText(#"{"type":"stop"}"#)
    }

    /// Cancel the current session without expecting a transcription result.
    func cancelSession() {
        finalResultDelivered = true  // suppress any incoming GoldReplace
        sendText(#"{"type":"stop"}"#)
    }

    /// Suppress any GoldReplace that is still in flight (e.g. user pressed Esc while transcribing).
    func discardPendingResult() {
        finalResultDelivered = true
    }

    // MARK: - Process management

    private func startProcess() {
        guard let backendDir = findBackendDirectory() else {
            print("[sidecar] backend directory not found (expected Cargo.toml in backend/)")
            return
        }

        let p = Process()
        let binaryPath = backendDir.appendingPathComponent("target/release/speakboard-be-sherpa").path

        // --config passes all settings; ENV vars (PORT, NUM_THREADS, etc.) override JSON if set.
        let configPath = settings.configFilePath.path

        if FileManager.default.isExecutableFile(atPath: binaryPath) {
            p.executableURL = URL(fileURLWithPath: binaryPath)
            p.arguments = ["--config", configPath]
            p.currentDirectoryURL = backendDir
        } else if let cargoPath = findCargoPath() {
            print("[sidecar] pre-built binary not found; using cargo run --release (first run may take a while)")
            p.executableURL = URL(fileURLWithPath: cargoPath)
            p.arguments = ["run", "--release", "--", "--config", configPath]
            p.currentDirectoryURL = backendDir
        } else {
            print("[sidecar] backend not runnable — run: cd backend && cargo build --release")
            return
        }

        // Inject the binary's directory into DYLD_LIBRARY_PATH so that
        // libonnxruntime (which has no LC_RPATH in the binary) can be found.
        let libDir = backendDir.appendingPathComponent("target/release").path
        var env = ProcessInfo.processInfo.environment
        let existing = env["DYLD_LIBRARY_PATH"].map { $0 + ":" } ?? ""
        env["DYLD_LIBRARY_PATH"] = existing + libDir
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            s.split(separator: "\n").forEach { print("[backend] \($0)") }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                print("[sidecar] process exited (code \(proc.terminationStatus))")
                self?.process = nil
                self?.isReady = false
                self?.wsTask = nil
            }
        }

        do {
            try p.run()
            process = p
            print("[sidecar] started pid \(p.processIdentifier)")
        } catch {
            print("[sidecar] failed to start process: \(error)")
            return
        }

        // Allow the server time to load the model before the first connection attempt.
        scheduleConnect(delay: 2.0)
    }

    private func findBackendDirectory() -> URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("backend")
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Cargo.toml").path
            ) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func findCargoPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.cargo/bin/cargo",
            "/usr/local/bin/cargo",
            "/opt/homebrew/bin/cargo",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - WebSocket

    private func connect() {
        guard shouldReconnect else { return }
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = urlSession.webSocketTask(with: url)
        wsTask = task
        task.resume()
        receiveLoop()
        print("[sidecar] connecting to \(url)")
    }

    private func scheduleConnect(delay: TimeInterval) {
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8)
                @unknown default:    text = nil
                }
                if let text { DispatchQueue.main.async { self.handleText(text) } }
                self.receiveLoop()
            case .failure(let error):
                // Suppress the log for expected disconnects (server closed after Stop).
                if !self.sessionStopped {
                    print("[sidecar] WS receive error: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { self.onDisconnected() }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String else { return }

        switch type_ {
        case "ready":
            reconnectAttempts = 0
            isReady = true
            print("[sidecar] ready")
            onReady?()

        case "partial":
            guard let t = json["text"] as? String, !t.isEmpty else { break }
            let pid = json["id"] as? String ?? "p0"
            if let idx = pendingPartials.firstIndex(where: { $0.id == pid }) {
                // Same id: this is a refinement of an existing segment — replace in-place.
                pendingPartials[idx].text = t
            } else {
                // New id: new speech segment — append.
                pendingPartials.append((id: pid, text: t))
            }
            let display = buildDisplayText()
            onPartial?(display)

        case "gold_replace":
            guard let t = json["text"] as? String, !t.isEmpty else { break }
            pendingPartials = []   // gold replaces all pending partials
            sessionGoldText = sessionGoldText.isEmpty ? t : sessionGoldText + " " + t
            if sessionStopped {
                guard !finalResultDelivered else { break }
                finalResultDelivered = true
                onFinalResult?(sessionGoldText)
            } else {
                onGoldUpdate?(sessionGoldText)
            }

        default:
            print("[sidecar] unknown message: \(type_)")
        }
    }

    private func onDisconnected() {
        guard shouldReconnect else { return }
        isReady = false
        wsTask = nil

        // If a session was stopped but no GoldReplace arrived before disconnect, deliver nil.
        if sessionStopped && !finalResultDelivered {
            finalResultDelivered = true
            onFinalResult?(sessionGoldText.isEmpty ? nil : sessionGoldText)
        }

        if sessionStopped {
            // Expected: server closed the connection after completing the session.
            // Reconnect immediately to have a hot standby ready for the next recording.
            reconnectAttempts = 0
            scheduleConnect(delay: 0.1)
        } else if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            print("[sidecar] reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts)")
            scheduleConnect(delay: 1.0)
        } else if process != nil {
            // The process is still running (e.g. cargo run is still compiling).
            // Keep retrying indefinitely instead of killing and restarting it.
            reconnectAttempts = 0
            print("[sidecar] process still running — retrying connection in 2 s")
            scheduleConnect(delay: 2.0)
        } else {
            // Process has exited on its own — restart it.
            print("[sidecar] process exited — restarting server")
            reconnectAttempts = 0
            restartServer()
        }
    }

    private func restartServer() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startProcess()
        }
    }

    private func buildDisplayText() -> String {
        let parts = ([sessionGoldText] + pendingPartials.map(\.text)).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private func sendText(_ text: String) {
        guard let task = wsTask else { return }
        task.send(.string(text)) { error in
            if let error { print("[sidecar] text send error: \(error)") }
        }
    }
}
