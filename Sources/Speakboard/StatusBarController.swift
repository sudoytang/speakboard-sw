import AppKit

final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init() {
        if let btn = item.button {
            btn.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Speakboard"
            )
        }
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Quit Speakboard",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
    }
}
