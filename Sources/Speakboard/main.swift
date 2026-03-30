import AppKit

// Accessory policy: no Dock icon, lives in the menu bar only.
NSApplication.shared.setActivationPolicy(.accessory)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
