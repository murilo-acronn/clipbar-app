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

    /// Whether some app has Secure Event Input turned on right now.
    ///
    /// Any process can enable it — a password field, a terminal with Secure
    /// Keyboard Entry on — and while it is on the system stops handing keystrokes
    /// to other apps. It is the standard reason a global shortcut "just stops
    /// working" for a while and then comes back on its own, with nothing on this
    /// side having changed. Worth reporting before anyone goes looking in here.
    static var secureInputIsActive: Bool { IsSecureEventInputEnabled() }

    /// Deliveries closer together than this are the same press, replayed.
    private static let minimumInterval: TimeInterval = 0.25

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

            // A press that lands while the main thread is busy is not lost:
            // Carbon queues it, and every queued copy is delivered the instant
            // the run loop breathes again. The callback here is a toggle, so a
            // burst of three replays reads as open-close-open — from the outside,
            // "the shortcut did nothing". Measured after a 13-second stall: three
            // deliveries inside 180 ms from one deliberate press.
            //
            // Nothing is lost by collapsing them. Nobody toggles a bar twice
            // inside a quarter of a second on purpose, and the timestamp advances
            // on the ignored copies too, so a long burst still collapses to one.
            let now = Date()
            if let last = HotKey.lastFiredAt, now.timeIntervalSince(last) < HotKey.minimumInterval {
                HotKey.lastFiredAt = now
                Log.hotKey.notice("ignored a queued repeat")
                return noErr
            }
            HotKey.lastFiredAt = now

            // The breadcrumb that separates "the key never arrived" from "the
            // key arrived and the panel failed to show". Those two look
            // identical from the outside and have nothing in common inside.
            Log.hotKey.notice("delivered id=\(hotKeyID.id, privacy: .public)")
            HotKey.callbacks[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
