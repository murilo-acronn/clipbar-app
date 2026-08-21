import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey.
///
/// Deliberately not NSEvent.addGlobalMonitorForEvents: that API needs the
/// Accessibility permission, this one does not. We only want to spend that
/// permission on auto-paste, which genuinely requires it.
final class HotKey {
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    /// Whether the most recent init succeeded. RegisterEventHotKey refuses a
    /// combination another app already owns, and the preferences window has to
    /// tell the user instead of showing a shortcut that does nothing.
    /// Whether the most recent `init?` returned without error.
    ///
    /// Nearly useless as a conflict check, and measured rather than assumed:
    /// with ClipBar actively holding ⌘⌥V, a second process registering the very
    /// same combination still got `noErr`. Carbon lets applications register
    /// duplicates and silently delivers the event to only one of them, so a
    /// successful registration says nothing about whether the key will ever
    /// arrive. `lastFiredAt` is the only honest signal.
    private(set) static var lastRegistrationSucceeded = true

    /// When a registered hot key last actually fired. The preferences window
    /// watches this to confirm a freshly recorded shortcut really reaches us
    /// instead of being swallowed by whichever app also claimed it.
    private(set) static var lastFiredAt: Date?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()

        id = HotKey.nextID
        HotKey.nextID += 1

        let hotKeyID = EventHotKeyID(signature: 0x434C_4250 /* 'CLBP' */, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        HotKey.lastRegistrationSucceeded = (status == noErr)
        guard status == noErr else { return nil }
        HotKey.callbacks[id] = onPress
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKey.callbacks[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            HotKey.lastFiredAt = Date()
            HotKey.callbacks[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
