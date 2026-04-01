import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var panel: FloatingPanelController!
    private var hotkey: GlobalHotkeyManager!
    private var sidecar: SidecarManager!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel    = FloatingPanelController()
        statusBar = StatusBarController()
        sidecar  = SidecarManager(settings: .shared)
        settingsWindow = SettingsWindowController(settings: .shared)

        hotkey = GlobalHotkeyManager(
            keyCode:   UInt32(SettingsStore.shared.hotkeyKeyCode),
            modifiers: UInt32(SettingsStore.shared.hotkeyModifiers),
            onPress:   { [weak self] in self?.panel.hotkeyPressed() },
            onRelease: { [weak self] in self?.panel.hotkeyReleased() }
        )

        settingsWindow.onSaveRestart = { [weak self] in
            guard let self else { return }
            self.sidecar.restart()
            self.hotkey.update(
                keyCode:   UInt32(SettingsStore.shared.hotkeyKeyCode),
                modifiers: UInt32(SettingsStore.shared.hotkeyModifiers)
            )
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
