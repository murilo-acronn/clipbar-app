import AppKit

/// A large look at the selected image, over the bar, for as long as the space
/// bar says so.
///
/// Deliberately *not* `QLPreviewPanel`. QuickLook previews files, and every
/// image in here is an encrypted blob — handing it to QuickLook would mean
/// writing the decrypted image to a temporary file first. Plaintext on disk,
/// outside the store, for a feature whose whole job is to look at something for
/// two seconds. Drawing the image ourselves costs less code than the file
/// handling would have, and nothing leaves the process.
///
/// Never key, and transparent to the mouse: the bar keeps the keyboard the
/// entire time, so Escape and the arrow keys go on working with no focus
/// handoff to get wrong.
final class PreviewPanel: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
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
        ignoresMouseEvents = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: Self.inset),
            imageView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Self.inset),
            imageView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Self.inset),
            imageView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Self.inset),
        ])

        contentView = backdrop
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static let inset: CGFloat = 10

    /// Shows `image` as large as it fits inside `area`, centred, never enlarged
    /// past its own pixels — a 32×32 favicon blown up to fill the screen is
    /// worse than the card it came from.
    func show(_ image: NSImage, in area: NSRect) {
        imageView.image = image

        let available = NSSize(width: max(area.width - Self.inset * 2, 1),
                               height: max(area.height - Self.inset * 2, 1))
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }

        let scale = min(available.width / source.width, available.height / source.height, 1)
        let target = NSSize(width: (source.width * scale).rounded() + Self.inset * 2,
                            height: (source.height * scale).rounded() + Self.inset * 2)

        setFrame(
            NSRect(x: (area.midX - target.width / 2).rounded(),
                   y: (area.midY - target.height / 2).rounded(),
                   width: target.width,
                   height: target.height),
            display: false
        )
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
        // The blob was decrypted to get here; there is no reason for it to stay
        // decrypted in a view that nobody is looking at.
        imageView.image = nil
    }
}
