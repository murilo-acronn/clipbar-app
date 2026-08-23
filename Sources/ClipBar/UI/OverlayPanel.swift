import AppKit

/// The bar that slides up from the bottom of the screen.
///
/// A panel rather than a plain NSWindow so it can sit at `.statusBar` level over
/// other apps and join every Space without ever becoming the main window.
///
/// `.nonactivatingPanel` is *not* here to keep ClipBar in the background —
/// OverlayController activates the app on purpose, because a panel that never
/// activates gets no key events while another app is frontmost, which kills
/// Escape and type-to-search. Focus returns to the previous app on dismiss, and
/// that is what makes paste land in the right window.
final class OverlayPanel: NSPanel {
    /// Called on Escape. Handled here rather than in SwiftUI: a borderless
    /// panel's hosting view never becomes first responder on its own, so
    /// `.onExitCommand` would never fire.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Borderless panels refuse key status unless we say otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
