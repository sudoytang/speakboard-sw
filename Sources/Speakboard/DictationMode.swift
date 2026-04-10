import Foundation

/// How the mic button triggers dictation.
enum DictationMode: Equatable {
    /// Hold the button to record; release to stop. (default)
    case hold
    /// First click starts recording, second click stops it.
    case toggle
    /// Click to start; automatically stops after `silenceDelay` seconds
    /// with no new speech detected from the backend.
    case autoStop(silenceDelay: Double)

    // MARK: - UserDefaults persistence

    private static let key = "dictationMode"

    static func load() -> DictationMode {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .hold }
        switch raw {
        case "hold":   return .hold
        case "toggle": return .toggle
        default:
            if raw.hasPrefix("autoStop:"),
               let d = Double(raw.dropFirst("autoStop:".count)) {
                return .autoStop(silenceDelay: d)
            }
            return .hold
        }
    }

    func save() {
        let raw: String
        switch self {
        case .hold:               raw = "hold"
        case .toggle:             raw = "toggle"
        case .autoStop(let d):    raw = "autoStop:\(d)"
        }
        UserDefaults.standard.set(raw, forKey: DictationMode.key)
    }

    // MARK: - Display

    var menuTitle: String {
        switch self {
        case .hold:               return "Hold to Speak"
        case .toggle:             return "Click to Stop"
        case .autoStop(let d):    return "Auto-stop \(formatDelay(d))"
        }
    }
}

private func formatDelay(_ d: Double) -> String {
    let ms = Int(d * 1000)
    return ms % 1000 == 0 ? "\(Int(d))s" : "\(ms)ms"
}
