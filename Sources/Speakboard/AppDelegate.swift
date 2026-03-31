import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var panel: FloatingPanelController!
    private var hotkey: GlobalHotkeyManager!
    private var sidecar: SidecarManager!   // backend process; no UI coupling

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanelController()
        statusBar = StatusBarController()
        hotkey = GlobalHotkeyManager(
            onPress:   { [weak self] in self?.panel.hotkeyPressed() },
            onRelease: { [weak self] in self?.panel.hotkeyReleased() }
        )
        sidecar = SidecarManager()
        sidecar.start()
        panel.sidecar = sidecar
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.stop()
    }
}
