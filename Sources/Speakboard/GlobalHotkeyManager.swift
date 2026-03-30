import Carbon

// MARK: - Global hotkey implementation
//
// Uses Carbon's RegisterEventHotKey API.
// No Accessibility or Input Monitoring permission required.
//
// Both kEventHotKeyPressed and kEventHotKeyReleased are registered so the caller
// can implement hold-to-record behaviour (onPress = start, onRelease = stop).
//
// CURRENT BINDING: ⌘⇧O
// To change the shortcut, edit the two constants below:
//   keyCode   – a kVK_* value from <Carbon/HIToolbox/Events.h>
//   modifiers – combine cmdKey / shiftKey / optionKey / controlKey

final class GlobalHotkeyManager {

    // MARK: - Shortcut constants  (edit here to remap)
    private let keyCode:   UInt32 = UInt32(kVK_ANSI_O)           // O
    private let modifiers: UInt32 = UInt32(cmdKey | shiftKey)     // ⌘⇧

    private let onPress: () -> Void
    private let onRelease: (() -> Void)?
    private var hotKeyRef:  EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        self.onPress = onPress
        self.onRelease = onRelease
        install()
    }

    deinit {
        if let r = hotKeyRef  { UnregisterEventHotKey(r) }
        if let r = handlerRef { RemoveEventHandler(r) }
    }

    // MARK: - Private

    private func install() {
        // Register for both press and release events.
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        mgr.onPress()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        mgr.onRelease?()
                    }
                }
                return noErr
            },
            2, &specs, selfPtr, &handlerRef
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
    precondition(s.count == 4)
    return s.utf8.enumerated().reduce(FourCharCode(0)) { acc, pair in
        (acc << 8) | FourCharCode(pair.element)
    }
}
