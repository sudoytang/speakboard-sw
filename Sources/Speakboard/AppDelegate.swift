import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var panel: FloatingPanelController!
    private var hotkey: GlobalHotkeyManager!
    private var sidecar: SidecarManager!
    private var settingsWindow: SettingsWindowController!
    private var inlineDictation: InlineDictationController!
    private var micButtonPanel: MicButtonPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel    = FloatingPanelController()
        statusBar = StatusBarController()
        sidecar  = SidecarManager(settings: .shared)
        settingsWindow = SettingsWindowController(settings: .shared)

        // Inline dictation (mic button — hold to dictate directly at cursor).
        inlineDictation = InlineDictationController()
        inlineDictation.sidecar = sidecar
        inlineDictation.panel   = panel

        micButtonPanel = MicButtonPanel()
        micButtonPanel.currentMode = inlineDictation.mode
        micButtonPanel.onPress   = { [weak self] in self?.inlineDictation.handlePress() }
        micButtonPanel.onRelease = { [weak self] in self?.inlineDictation.handleRelease() }
        micButtonPanel.onTap     = { [weak self] in self?.inlineDictation.handleTap() }
        micButtonPanel.onModeChange = { [weak self] mode in
            self?.inlineDictation.mode = mode
        }
        inlineDictation.onStateChange = { [weak self] active in
            self?.micButtonPanel.setRecording(active)
        }
        micButtonPanel.show()

        // Global hotkey: skip if inline dictation is currently active.
        hotkey = GlobalHotkeyManager(
            keyCode:   UInt32(SettingsStore.shared.hotkeyKeyCode),
            modifiers: UInt32(SettingsStore.shared.hotkeyModifiers),
            onPress:   { [weak self] in
                guard !(self?.inlineDictation.isActive ?? false) else { return }
                self?.panel.hotkeyPressed()
            },
            onRelease: { [weak self] in self?.panel.hotkeyReleased() }
        )

        settingsWindow.onSaveRestart = { [weak self] in
            guard let self else { return }
            self.sidecar.restart()
            self.hotkey.update(
                keyCode:   UInt32(SettingsStore.shared.hotkeyKeyCode),
                modifiers: UInt32(SettingsStore.shared.hotkeyModifiers)
            )
            self.panel.applySettings()
            self.inlineDictation.applySettings()
        }
        statusBar.onSettings = { [weak self] in
            self?.settingsWindow.showSettings()
        }

        sidecar.start()
        panel.sidecar = sidecar
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.stop()
    }
}
