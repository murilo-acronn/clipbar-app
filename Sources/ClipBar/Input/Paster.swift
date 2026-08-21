import AppKit
import Carbon.HIToolbox

/// Puts an item back on the pasteboard and, when allowed, presses Cmd+V for you.
enum Paster {
    /// Writes the item to the general pasteboard.
    static func place(_ item: ClipItem, blobs: BlobStore, monitor: ClipboardMonitor?) {
        let pasteboard = NSPasteboard.general
        // Our own write bumps changeCount; without this the item we just pasted
        // would be re-captured as a fresh copy.
        monitor?.ignoreNextChange = true
        pasteboard.clearContents()

        switch item.kind {
        case .image:
            if let path = item.blobPath, let data = try? blobs.read(path) {
                pasteboard.setData(data, forType: path.hasSuffix("png") ? .png : .tiff)
            }
        case .file:
            let urls = item.preview.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            if urls.isEmpty {
                pasteboard.setString(item.preview, forType: .string)
            } else {
                pasteboard.writeObjects(urls as [NSURL])
            }
        default:
            pasteboard.setString(item.preview, forType: .string)
        }
    }

    static var canAutoPaste: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for the Accessibility permission, showing the system prompt.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Synthesises Cmd+V into whichever app is frontmost.
    ///
    /// The flags are set explicitly rather than inherited: the hotkey that
    /// opened the bar was Cmd+Opt+V, and if Opt is still physically held when
    /// this fires, an inherited flag set would deliver Cmd+Opt+V to the target
    /// app — which is a different command entirely in most editors.
    static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
