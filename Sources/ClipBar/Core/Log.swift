import OSLog

/// The breadcrumbs that answer "why didn't the bar open?".
///
/// `os_log` rather than `NSLog`, and that is a measurement rather than a
/// preference: NSLog from this bundle never reached the unified log at all. The
/// blob sweep provably ran — sixteen files disappeared from disk — and its
/// NSLog line was nowhere, at any level, under any predicate. Whatever swallows
/// it, a named subsystem does not have the problem, and it puts the whole trail
/// one predicate away:
///
///     log stream --predicate 'subsystem == "io.local.clipbar"'
///
/// Nothing here may carry item content. The trail is about focus and timing,
/// and the pinboards this app holds contain real credentials.
enum Log {
    static let overlay = Logger(subsystem: "io.local.clipbar", category: "overlay")
    static let hotKey = Logger(subsystem: "io.local.clipbar", category: "hotkey")
    static let store = Logger(subsystem: "io.local.clipbar", category: "store")
}
