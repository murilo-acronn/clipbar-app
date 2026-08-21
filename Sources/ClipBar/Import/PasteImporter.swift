import AppKit
import SQLite3

private let SQLITE_TRANSIENT_IMPORT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One-shot migration of the pinboards out of Paste.
///
/// Only pinned items come across: the loose history is churn the user clears
/// anyway. Paste's own database is never opened in place — we copy it first,
/// so a running Paste can't have its WAL disturbed by us.
enum PasteImporter {
    struct Summary {
        var pinboards = 0
        var items = 0
        var images = 0
        var skipped: [String] = []
    }

    static func run(dryRun: Bool) throws {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste")

        guard FileManager.default.fileExists(atPath: container.appending(path: "db.sqlite").path) else {
            print("Não encontrei os dados do Paste em \(container.path)")
            return
        }

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipbar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let copy = workspace.appending(path: "db.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let source = container.appending(path: "db.sqlite\(suffix)")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: workspace.appending(path: "db.sqlite\(suffix)"))
        }

        var paste: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &paste, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("Não consegui abrir a cópia do banco do Paste")
            return
        }
        defer { sqlite3_close(paste) }

        let external = container.appending(path: ".db_SUPPORT/_EXTERNAL_DATA")
        let store = try Store(url: Paths.database)
        let blobs = try BlobStore(root: Paths.blobs)

        var summary = Summary()
        let existing = Set((try store.pinboards()).map(\.name))

        for board in pinboards(in: paste) {
            let targetID: Int64?
            if existing.contains(board.name) {
                targetID = (try store.pinboards()).first { $0.name == board.name }?.id
                print("• \(board.name) — já existe, reaproveitando")
            } else if dryRun {
                targetID = nil
                print("• \(board.name)  \(board.color)")
            } else {
                targetID = try store.createPinboard(name: board.name, color: board.color, sortIndex: summary.pinboards)
                print("• \(board.name)  \(board.color)")
            }
            summary.pinboards += 1

            for row in items(in: paste, listID: board.id) {
                guard let payload = PasteDecoder.decode(row.payload, externalRoot: external) else {
                    summary.skipped.append("\(board.name): item \(row.id) não decodificou")
                    continue
                }

                guard let item = makeItem(row: row, payload: payload, pinboardID: targetID,
                                          blobs: blobs, dryRun: dryRun) else {
                    summary.skipped.append("\(board.name): item \(row.id) sem conteúdo aproveitável")
                    continue
                }

                if item.kind == .image { summary.images += 1 }
                summary.items += 1
                if !dryRun {
                    let result = try store.upsert(item)
                    if let discarded = result.discardedBlobPath { blobs.delete(discarded) }
                }
            }
        }

        print("""

        \(dryRun ? "SIMULAÇÃO — nada foi gravado" : "IMPORTADO")
        \(summary.pinboards) pastas · \(summary.items) itens (\(summary.images) imagens)
        """)
        if !summary.skipped.isEmpty {
            print("\(summary.skipped.count) ignorados:")
            summary.skipped.prefix(15).forEach { print("  - \($0)") }
        }
    }

    // MARK: - Building

    private static func makeItem(row: ItemRow, payload: PasteDecoder.Payload, pinboardID: Int64?,
                                 blobs: BlobStore, dryRun: Bool) -> ClipItem? {
        let created = Date(timeIntervalSinceReferenceDate: row.createdAt)

        if let imageData = payload.byType["public.png"] ?? payload.byType["public.tiff"] {
            let size = NSImage(data: imageData)?.size ?? .zero
            let importedTitle = row.title?.isEmpty == false ? row.title : nil
            let label = row.title?.isEmpty == false
                ? row.title!
                : "Imagem \(Int(size.width))×\(Int(size.height))"
            let path = dryRun ? nil : try? blobs.write(imageData, extension: payload.byType["public.png"] != nil ? "png" : "tiff")
            guard let fingerprint = try? Crypto.fingerprint(imageData) else { return nil }
            return ClipItem(id: nil, kind: .image, title: label, preview: label,
                            fingerprint: fingerprint, blobPath: path, byteSize: imageData.count,
                            charCount: label.count, sourceBundleID: row.bundleID, sourceName: row.appName,
                            createdAt: created, lastUsedAt: created, pinboardID: pinboardID,
                            titleIsCustom: importedTitle.map { !$0.hasPrefix("Imagem") } ?? false)
        }

        let textData = payload.byType["public.utf8-plain-text"] ?? payload.byType["public.text"]
        guard let textData, let text = String(data: textData, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let fingerprint = try? Crypto.fingerprint(Data(text.utf8)) else { return nil }
        let title = row.title?.isEmpty == false
            ? row.title
            : text.split(separator: "\n").first.map(String.init)
        let derivedTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""

        return ClipItem(id: nil, kind: ClipKind.infer(fromText: text), title: title, preview: text,
                        fingerprint: fingerprint, blobPath: nil, byteSize: text.utf8.count,
                        charCount: text.count, sourceBundleID: row.bundleID, sourceName: row.appName,
                        createdAt: created, lastUsedAt: created, pinboardID: pinboardID,
                        titleIsCustom: title.map { $0 != derivedTitle } ?? false)
    }

    // MARK: - Reading Paste

    private struct BoardRow { var id: Int64; var name: String; var color: String }
    private struct ItemRow {
        var id: Int64; var title: String?; var createdAt: Double
        var bundleID: String?; var appName: String?; var payload: Data
    }

    private static func pinboards(in db: OpaquePointer?) -> [BoardRow] {
        var result: [BoardRow] = []
        query(db, """
            SELECT Z_PK, ZNAME, ZRAWATTRIBUTES FROM ZLISTENTITY
            WHERE json_extract(ZRAWATTRIBUTES, '$.type') = 'pinboard'
            ORDER BY ZCREATEDAT
            """) { stmt in
            let attributes = text(stmt, 2) ?? "{}"
            // colorCode is a packed ARGB int; the alpha byte is sometimes absent.
            var color = "#5B8DEF"
            if let data = attributes.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["colorCode"] as? UInt32 {
                color = String(format: "#%06X", code & 0xFF_FFFF)
            }
            result.append(BoardRow(id: sqlite3_column_int64(stmt, 0),
                                   name: text(stmt, 1) ?? "Sem nome",
                                   color: color))
        }
        return result
    }

    private static func items(in db: OpaquePointer?, listID: Int64) -> [ItemRow] {
        var result: [ItemRow] = []
        query(db, """
            SELECT i.Z_PK, i.ZTITLE, i.ZCREATEDAT, a.ZBUNDLEIDENTIFIER, a.ZNAME, d.ZRAWPASTEBOARDITEMS
            FROM ZITEMENTITY i
            JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK
            LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
            WHERE i.ZLIST = ?
            ORDER BY i.ZDISPLAYORDERINPINBOARD, i.ZCREATEDAT
            """, bind: { sqlite3_bind_int64($0, 1, listID) }) { stmt in
            guard let bytes = sqlite3_column_blob(stmt, 5) else { return }
            let count = Int(sqlite3_column_bytes(stmt, 5))
            result.append(ItemRow(
                id: sqlite3_column_int64(stmt, 0),
                title: text(stmt, 1),
                createdAt: sqlite3_column_double(stmt, 2),
                bundleID: text(stmt, 3),
                appName: text(stmt, 4),
                payload: Data(bytes: bytes, count: count)
            ))
        }
        return result
    }

    private static func query(_ db: OpaquePointer?, _ sql: String,
                              bind: ((OpaquePointer?) -> Void)? = nil,
                              row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQL falhou: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }
}
