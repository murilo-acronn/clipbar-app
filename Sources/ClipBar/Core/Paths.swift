import Foundation

enum Paths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipBar", isDirectory: true)
    }

    static var database: URL { support.appendingPathComponent("clipbar.sqlite") }
    static var blobs: URL { support.appendingPathComponent("blobs", isDirectory: true) }
}
