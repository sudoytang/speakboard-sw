import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var panel: FloatingPanelController!
    private var hotkey: GlobalHotkeyManager!
    private var sidecar: SidecarManager!   // backend process; no UI coupling

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanelController()
        statusBar = StatusBarController()
        hotkey = GlobalHotkeyManager { [weak self] in
            self?.panel.toggle()
        }
        sidecar = SidecarManager()
        sidecar.start()
        panel.sidecar = sidecar
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.stop()
    }
}
