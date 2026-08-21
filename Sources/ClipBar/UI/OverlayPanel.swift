import AppKit

/// The bar that slides up from the bottom of the screen.
///
/// The whole point of the panel (rather than a plain NSWindow) is
/// `.nonactivatingPanel`: it takes keyboard focus without activating ClipBar,
/// so the app you copied from stays frontmost and the paste lands there.
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
