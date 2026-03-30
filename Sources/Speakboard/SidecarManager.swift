import Foundation

// MARK: - Errors

enum SidecarError: LocalizedError {
    case uvNotFound
    case backendNotFound
    case notReady
    case httpError(Int)
    case invalidResponse
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:       return "Could not find the 'uv' executable."
        case .backendNotFound:  return "Could not find the backend directory."
        case .notReady:         return "Backend is not ready yet."
        case .httpError(let c): return "Server returned HTTP \(c)."
        case .invalidResponse:  return "Could not parse transcription response."
        case .network(let e):   return e.localizedDescription
        }
    }
}

// MARK: - SidecarManager
//
// Manages the Python backend sidecar process and its HTTP API.
// Lifecycle is driven by NSApplication notifications so this class is
// entirely self-contained and requires no changes to any frontend file.
//
// Integration steps:
//   1. Instantiate SidecarManager() once (e.g. in AppDelegate).
//   2. Call transcribe(audioData:completion:) whenever you have WAV audio.
//   3. That's it — start/stop are wired to app launch/terminate internally.

final class SidecarManager {

    // Whether the backend passed the /health check and is ready to accept requests.
    private(set) var isReady = false

    private let port = 8000
    private var process: Process?
    private var healthTimer: Timer?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 90
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    // MARK: - Init / deinit

    init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle (call from AppDelegate or anywhere)

    func start() {
        guard let uvPath = findExecutable("uv") else {
            print("[sidecar] uv not found – tried common paths")
            return
        }
        guard let backendDir = findBackendDirectory() else {
            print("[sidecar] backend directory not found")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: uvPath)
        p.arguments = ["run", "python", "-m", "speakboard", "serve", "--port", "\(port)"]
        p.currentDirectoryURL = backendDir

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            s.components(separatedBy: .newlines).filter { !$0.isEmpty }.forEach {
                print("[backend] \($0)")
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                print("[sidecar] process exited (code \(proc.terminationStatus))")
                self?.isReady = false
            }
        }

        do {
            try p.run()
        } catch {
            print("[sidecar] failed to start: \(error)")
            return
        }

        process = p
        startHealthPolling()
        print("[sidecar] started (pid \(p.processIdentifier))")
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let p = process {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        isReady = false
    }

    // MARK: - API

    /// POST WAV audio to /transcribe; calls completion with the transcript or an error.
    func transcribe(audioData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard isReady else {
            completion(.failure(SidecarError.notReady))
            return
        }

        var req = URLRequest(url: url("/transcribe"))
        req.httpMethod = "POST"
        req.httpBody   = audioData

        session.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(SidecarError.network(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(SidecarError.invalidResponse))
                return
            }
            guard http.statusCode == 200 else {
                completion(.failure(SidecarError.httpError(http.statusCode)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                completion(.failure(SidecarError.invalidResponse))
                return
            }
            completion(.success(text))
        }.resume()
    }

    // MARK: - Health polling

    private func startHealthPolling() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        session.dataTask(with: url("/health")) { [weak self] _, response, _ in
            guard let self else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard !self.isReady else { return }
                self.isReady = true
                self.healthTimer?.invalidate()
                self.healthTimer = nil
                print("[sidecar] backend ready")
            }
        }.resume()
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func findExecutable(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.cargo/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func findBackendDirectory() -> URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("backend")
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("pyproject.toml").path
            ) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
