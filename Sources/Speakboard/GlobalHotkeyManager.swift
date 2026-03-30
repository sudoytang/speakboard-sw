import Carbon

// MARK: - Global hotkey implementation
//
// Uses Carbon's RegisterEventHotKey API.
// This is the same mechanism used by system-wide shortcuts (e.g. Spotlight).
//
// PERMISSION: No Accessibility or Input Monitoring permission is required.
// The OS delivers the hotkey event to our app's Carbon event loop even when
// another application is the frontmost window.
//
// CURRENT BINDING: ⌘⇧O
// To change the shortcut, edit the two constants below:
//   keyCode   – a kVK_* value from <Carbon/HIToolbox/Events.h>
//   modifiers – combine cmdKey / shiftKey / optionKey / controlKey
//
// TOGGLE BEHAVIOUR: repeated ⌘⇧O presses toggle the panel (show ↔ hide).
// This is implemented in FloatingPanelController.toggle().

final class GlobalHotkeyManager {

    // MARK: - Shortcut constants  (edit here to remap)
    private let keyCode:   UInt32 = UInt32(kVK_ANSI_O)           // O
    private let modifiers: UInt32 = UInt32(cmdKey | shiftKey)     // ⌘⇧

    private let callback: () -> Void
    private var hotKeyRef:  EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(callback: @escaping () -> Void) {
        self.callback = callback
        install()
    }

    deinit {
        if let r = hotKeyRef  { UnregisterEventHotKey(r) }
        if let r = handlerRef { RemoveEventHandler(r) }
    }

    // MARK: - Private

    private func install() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                DispatchQueue.main.async { mgr.callback() }
                return noErr
            },
            1, &spec, selfPtr, &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: fourCharCode("SBDM"), id: 1)
        RegisterEventHotKey(
            keyCode, modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0, &hotKeyRef
        )
    }
}

// MARK: - Helpers

private func fourCharCode(_ s: String) -> FourCharCode {
    precondition(s.count == 4, "FourCharCode string must be exactly 4 ASCII characters")
    return s.utf8.enumerated().reduce(FourCharCode(0)) { acc, pair in
        (acc << 8) | FourCharCode(pair.element)
    }
}
