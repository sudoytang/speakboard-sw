import Foundation

// Persists backend configuration in UserDefaults and serializes it to a JSON
// file that is passed to the backend via --config.
//
// Priority (backend resolution, highest → lowest):
//   1. ENV vars set by the user's shell (PORT, NUM_THREADS, MODEL_PATH, TOKENS_PATH)
//   2. JSON config file produced by this store
//   3. Backend built-in defaults
//
// Note: silence_rms_threshold, partial_silence_secs, gold_silence_secs,
// max_gold_secs, min_transcribe_secs, and min_speech_secs are JSON-only
// (no corresponding ENV vars in the backend).

final class SettingsStore {

    static let shared = SettingsStore()

    // MARK: - Defaults (must match backend's ResolvedConfig::default())

    static let defaultPort: Int = 8080
    static let defaultNumThreads: Int = 4
    static let defaultSilenceRmsThreshold: Double = 0.02
    static let defaultPartialSilenceSecs: Double = 0.8
    static let defaultGoldSilenceSecs: Double = 2.0
    static let defaultMaxGoldSecs: Double = 30.0
    static let defaultMinTranscribeSecs: Double = 0.5
    static let defaultMinSpeechSecs: Double = 0.3

    // MARK: - Persisted values

    private let ud = UserDefaults.standard
    private let ns = "speakboard.backend."

    var port: Int {
        get { ud.object(forKey: ns + "port") as? Int ?? Self.defaultPort }
        set { ud.set(newValue, forKey: ns + "port") }
    }
    var numThreads: Int {
        get { ud.object(forKey: ns + "numThreads") as? Int ?? Self.defaultNumThreads }
        set { ud.set(newValue, forKey: ns + "numThreads") }
    }
    var silenceRmsThreshold: Double {
        get { ud.object(forKey: ns + "silenceRmsThreshold") as? Double ?? Self.defaultSilenceRmsThreshold }
        set { ud.set(newValue, forKey: ns + "silenceRmsThreshold") }
    }
    var partialSilenceSecs: Double {
        get { ud.object(forKey: ns + "partialSilenceSecs") as? Double ?? Self.defaultPartialSilenceSecs }
        set { ud.set(newValue, forKey: ns + "partialSilenceSecs") }
    }
    var goldSilenceSecs: Double {
        get { ud.object(forKey: ns + "goldSilenceSecs") as? Double ?? Self.defaultGoldSilenceSecs }
        set { ud.set(newValue, forKey: ns + "goldSilenceSecs") }
    }
    var maxGoldSecs: Double {
        get { ud.object(forKey: ns + "maxGoldSecs") as? Double ?? Self.defaultMaxGoldSecs }
        set { ud.set(newValue, forKey: ns + "maxGoldSecs") }
    }
    var minTranscribeSecs: Double {
        get { ud.object(forKey: ns + "minTranscribeSecs") as? Double ?? Self.defaultMinTranscribeSecs }
        set { ud.set(newValue, forKey: ns + "minTranscribeSecs") }
    }
    var minSpeechSecs: Double {
        get { ud.object(forKey: ns + "minSpeechSecs") as? Double ?? Self.defaultMinSpeechSecs }
        set { ud.set(newValue, forKey: ns + "minSpeechSecs") }
    }
    // Empty string → omit from JSON (backend uses auto-download)
    var modelPath: String {
        get { ud.string(forKey: ns + "modelPath") ?? "" }
        set { ud.set(newValue, forKey: ns + "modelPath") }
    }
    var tokensPath: String {
        get { ud.string(forKey: ns + "tokensPath") ?? "" }
        set { ud.set(newValue, forKey: ns + "tokensPath") }
    }

    // MARK: - Hotkey (Carbon key code + modifiers)
    // Default: ⌃⌘Z (controlKey | cmdKey = 4096 + 256 = 4352, kVK_ANSI_Z = 6)

    static let defaultHotkeyKeyCode: Int = 6       // kVK_ANSI_Z
    static let defaultHotkeyModifiers: Int = 4352  // cmdKey | controlKey

    var hotkeyKeyCode: Int {
        get { ud.object(forKey: ns + "hotkeyKeyCode") as? Int ?? Self.defaultHotkeyKeyCode }
        set { ud.set(newValue, forKey: ns + "hotkeyKeyCode") }
    }
    var hotkeyModifiers: Int {
        get { ud.object(forKey: ns + "hotkeyModifiers") as? Int ?? Self.defaultHotkeyModifiers }
        set { ud.set(newValue, forKey: ns + "hotkeyModifiers") }
    }

    // MARK: - Reset

    func resetToDefaults() {
        [ns + "port", ns + "numThreads", ns + "silenceRmsThreshold",
         ns + "partialSilenceSecs", ns + "goldSilenceSecs", ns + "maxGoldSecs",
         ns + "minTranscribeSecs", ns + "minSpeechSecs",
         ns + "modelPath", ns + "tokensPath",
         ns + "hotkeyKeyCode", ns + "hotkeyModifiers"].forEach { ud.removeObject(forKey: $0) }
    }

    // MARK: - Config file

    var configFilePath: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speakboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Write only the fields that matter to the JSON config file.
    /// Returns the file URL for passing to the backend via --config.
    @discardableResult
    func writeConfigFile() throws -> URL {
        var dict: [String: Any] = [
            "port":                     port,
            "num_threads":              numThreads,
            "silence_rms_threshold":    silenceRmsThreshold,
            "partial_silence_secs":     partialSilenceSecs,
            "gold_silence_secs":        goldSilenceSecs,
            "max_gold_secs":            maxGoldSecs,
            "min_transcribe_secs":      minTranscribeSecs,
            "min_speech_secs":          minSpeechSecs,
        ]
        if !modelPath.isEmpty  { dict["model_path"]   = modelPath }
        if !tokensPath.isEmpty { dict["tokens_path"]  = tokensPath }

        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configFilePath)
        return configFilePath
    }
}
