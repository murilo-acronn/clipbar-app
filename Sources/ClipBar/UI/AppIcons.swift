import AppKit

/// Source-app icons, cached — NSWorkspace hits the disk otherwise, and the bar
/// redraws these on every keystroke.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
