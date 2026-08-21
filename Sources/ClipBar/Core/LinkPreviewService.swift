import AppKit
import LinkPresentation

/// Fetches link metadata only after the user opts in. The URL itself remains
/// the clipboard payload; page titles and images are presentation-only data.
final class LinkPreviewService {
    var onUpdate: (() -> Void)?

    private let store: Store
    private let blobs: BlobStore
    private var providers: [Int64: LPMetadataProvider] = [:]

    init(store: Store, blobs: BlobStore) {
        self.store = store
        self.blobs = blobs
    }

    func fetch(itemID: Int64, url: URL) {
        guard Preferences.linkPreviewsEnabled,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              (try? store.needsLinkMetadata(id: itemID)) == true,
              providers[itemID] == nil
        else { return }

        let provider = LPMetadataProvider()
        provider.timeout = 15
        providers[itemID] = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            guard let self else { return }

            let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = metadata?.originalURL?.host(percentEncoded: false)
                ?? metadata?.url?.host(percentEncoded: false)
                ?? url.host(percentEncoded: false)
            guard let imageProvider = metadata?.imageProvider ?? metadata?.iconProvider else {
                DispatchQueue.main.async {
                    self.finish(itemID: itemID, title: title, domain: domain, image: nil)
                }
                return
            }

            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                DispatchQueue.main.async {
                    self.finish(itemID: itemID, title: title, domain: domain,
                                image: object as? NSImage)
                }
            }
        }
    }

    private func finish(itemID: Int64, title: String?, domain: String?, image: NSImage?) {
        defer { providers[itemID] = nil }

        let imagePath = image
            .flatMap(Self.previewData)
            .flatMap { try? blobs.write($0, extension: "jpg") }

        do {
            let previous = try store.setLinkMetadata(
                id: itemID,
                title: title?.isEmpty == false ? title : nil,
                imagePath: imagePath,
                domain: domain
            )
            if let previous { blobs.delete(previous) }
            onUpdate?()
        } catch {
            if let imagePath { blobs.delete(imagePath) }
        }
    }

    /// Metadata providers can return full-resolution hero images. A card needs
    /// nowhere near that much data, even on a Retina display.
    private static func previewData(_ image: NSImage) -> Data? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }

        let bounds = NSSize(width: 1200, height: 720)
        let scale = min(1, bounds.width / source.width, bounds.height / source.height)
        let target = NSSize(width: max(1, (source.width * scale).rounded()),
                            height: max(1, (source.height * scale).rounded()))
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: source),
                   operation: .copy, fraction: 1)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
