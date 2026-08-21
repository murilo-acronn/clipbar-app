import Carbon.HIToolbox
import Foundation

enum Preferences {
    private static let defaults = UserDefaults.standard

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    static var captureSoundEnabled: Bool {
        get { bool("captureSoundEnabled", default: true) }
        set { defaults.set(newValue, forKey: "captureSoundEnabled") }
    }

    static var captureSoundName: String {
        get { defaults.string(forKey: "captureSoundName") ?? Feedback.defaultCaptureSound }
        set { defaults.set(newValue, forKey: "captureSoundName") }
    }

    static var pasteSoundEnabled: Bool {
        get { bool("pasteSoundEnabled", default: true) }
        set { defaults.set(newValue, forKey: "pasteSoundEnabled") }
    }

    static var pasteSoundName: String {
        get { defaults.string(forKey: "pasteSoundName") ?? Feedback.defaultPasteSound }
        set { defaults.set(newValue, forKey: "pasteSoundName") }
    }

    static var autoPasteEnabled: Bool {
        get { bool("autoPasteEnabled", default: true) }
        set { defaults.set(newValue, forKey: "autoPasteEnabled") }
    }

    static var historyLimit: Int {
        get { defaults.object(forKey: "historyLimit") as? Int ?? 500 }
        set { defaults.set(newValue, forKey: "historyLimit") }
    }

    /// Default on: a password manager marking its copy as concealed is the main
    /// thing standing between this app and a history full of credentials.
    static var ignoreConcealedContent: Bool {
        get { bool("ignoreConcealedContent", default: true) }
        set { defaults.set(newValue, forKey: "ignoreConcealedContent") }
    }

    static var ignoreTransientContent: Bool {
        get { bool("ignoreTransientContent", default: true) }
        set { defaults.set(newValue, forKey: "ignoreTransientContent") }
    }

    /// Off by default: fetching a preview tells the copied website that this
    /// machine requested its page, unlike every other ClipBar feature.
    static var linkPreviewsEnabled: Bool {
        get { bool("linkPreviewsEnabled", default: false) }
        set { defaults.set(newValue, forKey: "linkPreviewsEnabled") }
    }

    /// Days a loose item survives before being swept, or 0 to keep it forever.
    /// Items filed in a pinboard are never touched by this.
    static var historyRetentionDays: Int {
        get { defaults.object(forKey: "historyRetentionDays") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "historyRetentionDays") }
    }

    /// Apps whose copies are never captured. The pinboards hold real credentials,
    /// so the point of this list is to keep a password manager's clipboard out of
    /// the history even when it forgets to mark the item concealed.
    static var blockedBundleIDs: [String] {
        get { defaults.stringArray(forKey: "blockedBundleIDs") ?? [] }
        set { defaults.set(newValue, forKey: "blockedBundleIDs") }
    }

    // MARK: - Global hotkey
    //
    // Stored as Carbon values because that is what RegisterEventHotKey takes.
    // The label is captured when the shortcut is recorded rather than derived
    // from the key code: translating a virtual key back to the character it
    // prints means going through the current keyboard layout, and we already
    // had the character in hand at record time.

    static var hotKeyCode: UInt32 {
        get { UInt32(defaults.object(forKey: "hotKeyCode") as? Int ?? Int(kVK_ANSI_V)) }
        set { defaults.set(Int(newValue), forKey: "hotKeyCode") }
    }

    static var hotKeyModifiers: UInt32 {
        get { UInt32(defaults.object(forKey: "hotKeyModifiers") as? Int ?? (cmdKey | optionKey)) }
        set { defaults.set(Int(newValue), forKey: "hotKeyModifiers") }
    }

    static var hotKeyLabel: String {
        get { defaults.string(forKey: "hotKeyLabel") ?? "⌘⌥V" }
        set { defaults.set(newValue, forKey: "hotKeyLabel") }
    }

    /// First launch after install shows the welcome window, once.
    static var hasSeenWelcome: Bool {
        get { bool("hasSeenWelcome", default: false) }
        set { defaults.set(newValue, forKey: "hasSeenWelcome") }
    }

    static func resetHotKeyToDefault() {
        for key in ["hotKeyCode", "hotKeyModifiers", "hotKeyLabel"] {
            defaults.removeObject(forKey: key)
        }
    }
}
