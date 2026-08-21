import AppKit

/// Card-sized thumbnails, cached.
///
/// Deliberately downscales on the way in: the PRINTS pinboard holds 2560×1080
/// screenshots, and holding twenty of those at full size just to draw them at
/// 176pt wide would cost hundreds of megabytes for nothing.
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]
    private static var insertionOrder: [String] = []
    private static let maxEntries = 300
    private static let maxSize = NSSize(width: 472, height: 360)  // 2x for Retina

    static var blobs: BlobStore?

    static func image(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let blobs,
              let data = try? blobs.read(path),
              let full = NSImage(data: data)
        else { return nil }

        let thumbnail = downscale(full)
        store(thumbnail, for: path)
        return thumbnail
    }

    /// Files are stored by path, not copied into the blob store, so their preview
    /// has to come off disk. Keyed apart from blob paths to avoid a collision.
    static func image(forFile path: String) -> NSImage? {
        let key = "file:" + path
        if let cached = cache[key] { return cached }

        let ext = (path as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext),
              FileManager.default.fileExists(atPath: path),
              let full = NSImage(contentsOfFile: path)
        else { return nil }

        let thumbnail = downscale(full)
        store(thumbnail, for: key)
        return thumbnail
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp",
    ]

    static func clear() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private static func store(_ image: NSImage, for key: String) {
        if cache[key] == nil { insertionOrder.append(key) }
        cache[key] = image

        let overflow = cache.count - maxEntries
        guard overflow > 0 else { return }
        for expired in insertionOrder.prefix(overflow) { cache.removeValue(forKey: expired) }
        insertionOrder.removeFirst(overflow)
    }

    private static func downscale(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > maxSize.width || size.height > maxSize.height else { return image }

        let scale = min(maxSize.width / size.width, maxSize.height / size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        output.unlockFocus()
        return output
    }
}
