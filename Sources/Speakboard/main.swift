import AppKit

// Accessory policy: no Dock icon, lives in the menu bar only.
NSApplication.shared.setActivationPolicy(.accessory)

// Forward SIGINT/SIGTERM to NSApp.terminate so applicationWillTerminate
// fires even when the process is killed from the terminal (e.g. ^C on swift run).
let _handler: @convention(c) (Int32) -> Void = { _ in
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
}
signal(SIGINT,  _handler)
signal(SIGTERM, _handler)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
