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

    /// Whether visiting this URL could spend something.
    ///
    /// Building a preview means a GET from this machine, and some links are
    /// consumed by being visited: a sign-in link from an email, a password
    /// reset, a one-time invite. Copying one of those and having the preview
    /// burn it is silent and unrecoverable — the user only finds out when the
    /// link they meant to click says it has already been used.
    ///
    /// So this deliberately over-refuses. Guessing wrong in this direction
    /// costs a thumbnail. Guessing wrong in the other costs someone their login.
    static func carriesCredential(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return true }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        for item in components?.queryItems ?? [] {
            if credentialNames.contains(item.name.lowercased()) { return true }
            // An opaque value this long is not a search term or a page number.
            if (item.value?.count ?? 0) >= 24 { return true }
        }

        if let fragment = components?.fragment,
           fragment.count >= 24 || credentialNames.contains(where: { fragment.lowercased().contains($0) }) {
            return true
        }

        // The same secret, spelled as a path: /invite/9f3c…, /reset/AbCdEf…
        return url.pathComponents.contains { $0.count >= 24 && !$0.contains(".") }
    }

    private static let credentialNames: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization",
        "code", "key", "apikey", "api_key", "secret", "signature", "sig",
        "otp", "passcode", "password", "pwd", "magic", "invite", "invitation",
        "reset", "confirm", "confirmation", "verify", "verification",
        "session", "sid", "jwt", "ticket", "nonce", "state",
    ]

    func fetch(itemID: Int64, url: URL) {
        guard Preferences.linkPreviewsEnabled,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !Self.carriesCredential(url),
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
