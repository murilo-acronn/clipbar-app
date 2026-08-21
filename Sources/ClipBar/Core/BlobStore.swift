import CryptoKit
import Foundation

/// Images and files live on disk, not in the database: SQLite is happiest with
/// small rows, and a 300MB screenshot pinboard would make every query crawl.
/// Blobs are sealed with the same key as everything else.
final class BlobStore {
    private let root: URL

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Returns the store-relative path to hand back to `read`.
    @discardableResult
    func write(_ data: Data, extension ext: String) throws -> String {
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        // One level of fan-out keeps directory listings usable at scale.
        let shard = String(name.prefix(2))
        let dir = root.appendingPathComponent(shard, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sealed = try Crypto.seal(data)
        try sealed.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return "\(shard)/\(name)"
    }

    func read(_ relativePath: String) throws -> Data {
        let data = try Data(contentsOf: url(for: relativePath))
        return try Crypto.open(data)
    }

    func delete(_ relativePath: String) {
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }

    func size(_ relativePath: String) -> Int {
        let values = try? url(for: relativePath).resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }
}
