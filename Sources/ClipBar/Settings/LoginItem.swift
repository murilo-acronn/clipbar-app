import Foundation
import ServiceManagement

/// Launch at login, via the modern API — no helper bundle, no login item plist.
///
/// SMAppService registers the app by its bundle identity, so it only works for a
/// copy in /Applications that is signed. A build running from build/ will fail
/// here, and that failure is worth showing rather than swallowing.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
