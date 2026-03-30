import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var panel: FloatingPanelController!
    private var hotkey: GlobalHotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanelController()
        statusBar = StatusBarController()
        // Global shortcut ⌘⇧O → show floating panel.
        // To change the key binding, edit the constants in GlobalHotkeyManager.swift.
        hotkey = GlobalHotkeyManager { [weak self] in
            self?.panel.toggle()
        }
    }
}
