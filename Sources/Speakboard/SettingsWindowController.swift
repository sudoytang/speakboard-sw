import AppKit
import Carbon

// Settings window for configuring the backend and global hotkey.
// Changes take effect after "Save & Restart Backend".

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let settings: SettingsStore

    /// Called when the user saves; the caller should restart the backend and re-register the hotkey.
    var onSaveRestart: (() -> Void)?

    // MARK: - Form fields

    private let portField          = SettingsWindowController.numberField()
    private let threadsField       = SettingsWindowController.numberField()
    private let silenceRmsField    = SettingsWindowController.numberField()
    private let partialField       = SettingsWindowController.numberField()
    private let goldField          = SettingsWindowController.numberField()
    private let maxGoldField       = SettingsWindowController.numberField()
    private let minTranscribeField = SettingsWindowController.numberField()
    private let minSpeechField     = SettingsWindowController.numberField()
    private let modelPathField     = SettingsWindowController.pathField()
    private let tokensPathField    = SettingsWindowController.pathField()

    // MARK: - Hotkey recorder state

    private let hotkeyDisplayField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        f.alignment = .center
        f.bezelStyle = .roundedBezel
        f.isBordered = true
        f.backgroundColor = .controlBackgroundColor
        return f
    }()
    private let hotkeyRecordBtn = NSButton(title: "Record", target: nil, action: nil)
    private var recordedKeyCode: UInt32 = 0
    private var recordedModifiers: UInt32 = 0
    private var isRecordingHotkey = false
    private var hotkeyMonitor: Any?

    // MARK: - Init

    init(settings: SettingsStore) {
        self.settings = settings
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Speakboard Settings"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Show

    func showSettings() {
        loadValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 8

        // Helper: section header row
        @discardableResult
        func header(_ title: String) -> NSGridRow {
            let lbl = NSTextField(labelWithString: title.uppercased())
            lbl.font = .systemFont(ofSize: 11, weight: .semibold)
            lbl.textColor = .secondaryLabelColor
            let row = grid.addRow(with: [lbl, NSGridCell.emptyContentView])
            row.topPadding = 12
            return row
        }

        // Helper: form row with optional unit suffix
        func row(_ label: String, field: NSTextField, unit: String = "") {
            let lbl = NSTextField(labelWithString: label)
            lbl.alignment = .right
            if unit.isEmpty {
                grid.addRow(with: [lbl, field])
            } else {
                let unitLbl = NSTextField(labelWithString: unit)
                unitLbl.textColor = .secondaryLabelColor
                let hStack = NSStackView(views: [field, unitLbl])
                hStack.spacing = 4
                hStack.alignment = .centerY
                grid.addRow(with: [lbl, hStack])
            }
        }

        // Helper: path row with Browse button
        func pathRow(_ label: String, field: NSTextField, action: Selector) {
            let lbl = NSTextField(labelWithString: label)
            lbl.alignment = .right
            let btn = NSButton(title: "…", target: self, action: action)
            btn.bezelStyle = .rounded
            btn.setContentHuggingPriority(.required, for: .horizontal)
            let hStack = NSStackView(views: [field, btn])
            hStack.spacing = 6
            hStack.alignment = .centerY
            grid.addRow(with: [lbl, hStack])
        }

        // Hotkey recorder row
        hotkeyRecordBtn.target = self
        hotkeyRecordBtn.action = #selector(toggleHotkeyRecording)
        hotkeyRecordBtn.bezelStyle = .rounded
        hotkeyRecordBtn.setContentHuggingPriority(.required, for: .horizontal)
        let hotkeyStack = NSStackView(views: [hotkeyDisplayField, hotkeyRecordBtn])
        hotkeyStack.spacing = 8
        hotkeyStack.alignment = .centerY

        header("Hotkey")
        let hotkeyLbl = NSTextField(labelWithString: "Global shortcut")
        hotkeyLbl.alignment = .right
        grid.addRow(with: [hotkeyLbl, hotkeyStack])

        header("Server")
        row("Port",    field: portField)
        row("Threads", field: threadsField)

        header("VAD")
        row("Silence RMS threshold", field: silenceRmsField)
        row("Partial silence",       field: partialField,    unit: "s")
        row("Gold silence",          field: goldField,       unit: "s")
        row("Max segment",           field: maxGoldField,    unit: "s")

        header("Transcription")
        row("Min transcribe", field: minTranscribeField, unit: "s")
        row("Min speech",     field: minSpeechField,     unit: "s")

        header("Model (optional — leave blank for auto-download)")
        pathRow("Model path",  field: modelPathField,  action: #selector(browseModel))
        pathRow("Tokens path", field: tokensPathField, action: #selector(browseTokens))

        // Fix label column alignment and width
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 160

        content.addSubview(grid)

        // Buttons
        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        resetBtn.bezelStyle = .rounded

        let saveBtn = NSButton(title: "Save & Restart Backend", target: self, action: #selector(saveAndRestart))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        let btnStack = NSStackView(views: [resetBtn, NSView(), saveBtn])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.spacing = 8
        content.addSubview(btnStack)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            btnStack.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            btnStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            btnStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btnStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Load / save

    private func loadValues() {
        recordedKeyCode   = UInt32(settings.hotkeyKeyCode)
        recordedModifiers = UInt32(settings.hotkeyModifiers)
        hotkeyDisplayField.stringValue = Self.hotkeyDisplayString(
            keyCode: recordedKeyCode, modifiers: recordedModifiers
        )
        portField.stringValue          = "\(settings.port)"
        threadsField.stringValue       = "\(settings.numThreads)"
        silenceRmsField.stringValue    = format(settings.silenceRmsThreshold)
        partialField.stringValue       = format(settings.partialSilenceSecs)
        goldField.stringValue          = format(settings.goldSilenceSecs)
        maxGoldField.stringValue       = format(settings.maxGoldSecs)
        minTranscribeField.stringValue = format(settings.minTranscribeSecs)
        minSpeechField.stringValue     = format(settings.minSpeechSecs)
        modelPathField.stringValue     = settings.modelPath
        tokensPathField.stringValue    = settings.tokensPath
    }

    @objc private func saveAndRestart() {
        stopHotkeyRecording(accept: false)
        if recordedKeyCode != 0 {
            settings.hotkeyKeyCode  = Int(recordedKeyCode)
            settings.hotkeyModifiers = Int(recordedModifiers)
        }
        settings.port                  = Int(portField.stringValue)          ?? SettingsStore.defaultPort
        settings.numThreads            = Int(threadsField.stringValue)       ?? SettingsStore.defaultNumThreads
        settings.silenceRmsThreshold   = Double(silenceRmsField.stringValue) ?? SettingsStore.defaultSilenceRmsThreshold
        settings.partialSilenceSecs    = Double(partialField.stringValue)    ?? SettingsStore.defaultPartialSilenceSecs
        settings.goldSilenceSecs       = Double(goldField.stringValue)       ?? SettingsStore.defaultGoldSilenceSecs
        settings.maxGoldSecs           = Double(maxGoldField.stringValue)    ?? SettingsStore.defaultMaxGoldSecs
        settings.minTranscribeSecs     = Double(minTranscribeField.stringValue) ?? SettingsStore.defaultMinTranscribeSecs
        settings.minSpeechSecs         = Double(minSpeechField.stringValue)  ?? SettingsStore.defaultMinSpeechSecs
        settings.modelPath             = modelPathField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.tokensPath            = tokensPathField.stringValue.trimmingCharacters(in: .whitespaces)

        do {
            try settings.writeConfigFile()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to write config file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }

        window?.orderOut(nil)
        onSaveRestart?()
    }

    @objc private func resetDefaults() {
        settings.resetToDefaults()
        loadValues()
    }

    // MARK: - Hotkey recorder

    @objc private func toggleHotkeyRecording() {
        if isRecordingHotkey { stopHotkeyRecording(accept: false) }
        else { startHotkeyRecording() }
    }

    private func startHotkeyRecording() {
        isRecordingHotkey = true
        hotkeyRecordBtn.title = "Cancel"
        hotkeyDisplayField.stringValue = "Press keys…"

        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = Self.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return event }  // require at least one modifier
            self.recordedKeyCode   = UInt32(event.keyCode)
            self.recordedModifiers = mods
            self.hotkeyDisplayField.stringValue = Self.hotkeyDisplayString(
                keyCode: self.recordedKeyCode, modifiers: self.recordedModifiers
            )
            self.stopHotkeyRecording(accept: true)
            return nil  // consume the event
        }
    }

    private func stopHotkeyRecording(accept: Bool) {
        guard isRecordingHotkey else { return }
        isRecordingHotkey = false
        hotkeyRecordBtn.title = "Record"
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
        if !accept {
            // Restore display to the currently-recorded (not-yet-saved) value
            hotkeyDisplayField.stringValue = Self.hotkeyDisplayString(
                keyCode: recordedKeyCode, modifiers: recordedModifiers
            )
        }
    }

    // MARK: - Hotkey display helpers

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    private static func keyName(for code: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",  7: "X",
            8: "C",  9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",  50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[code] ?? "(\(code))"
    }

    // MARK: - File pickers

    @objc private func browseModel() {
        browse(field: modelPathField, title: "Select model .onnx file", ext: "onnx")
    }

    @objc private func browseTokens() {
        browse(field: tokensPathField, title: "Select tokens.txt file", ext: "txt")
    }

    private func browse(field: NSTextField, title: String, ext: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    // MARK: - Helpers

    private func format(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }

    private static func numberField() -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "default"
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    private static func pathField() -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "(auto)"
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }
}
