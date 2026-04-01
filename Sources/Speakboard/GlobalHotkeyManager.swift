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
// The active key binding is read from SettingsStore at init time and can be
// updated at runtime via update(keyCode:modifiers:).
//
// HOLD BEHAVIOUR: key-down → onPress (show panel + start recording)
//                 key-up   → onRelease (stop recording + transcribe)

final class GlobalHotkeyManager {

    private let onPress:   () -> Void
    private let onRelease: () -> Void
    private var hotKeyRef:  EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32,
         onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress   = onPress
        self.onRelease = onRelease
        installHandler()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let r = hotKeyRef  { UnregisterEventHotKey(r) }
        if let r = handlerRef { RemoveEventHandler(r) }
    }

    /// Unregister the current hotkey and register a new one.
    func update(keyCode: UInt32, modifiers: UInt32) {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        register(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Private

    private func installHandler() {
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = specs.withUnsafeBufferPointer { buf in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let ptr = userData, let event else {
                        return OSStatus(eventNotHandledErr)
                    }
                    let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                    switch GetEventKind(event) {
                    case UInt32(kEventHotKeyPressed):
                        DispatchQueue.main.async { mgr.onPress() }
                    case UInt32(kEventHotKeyReleased):
                        DispatchQueue.main.async { mgr.onRelease() }
                    default: break
                    }
                    return noErr
                },
                specs.count, buf.baseAddress, selfPtr, &handlerRef
            )
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SBDM"), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Helpers

private func fourCharCode(_ s: String) -> FourCharCode {
    precondition(s.count == 4, "FourCharCode string must be exactly 4 ASCII characters")
    return s.utf8.enumerated().reduce(FourCharCode(0)) { acc, pair in
        (acc << 8) | FourCharCode(pair.element)
    }
}
