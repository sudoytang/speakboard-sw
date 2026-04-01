import AppKit

final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    var onSettings: (() -> Void)?

    init() {
        if let btn = item.button {
            btn.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Speakboard"
            )
        }
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Speakboard",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
    }

    @objc private func openSettings() {
        onSettings?()
    }
}
