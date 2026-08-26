import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Pinboard {
    var id: Int64?
    var name: String
    var color: String          // "#RRGGBB"
    var requiresAuth: Bool     // reserved: per-pinboard Touch ID gate
    var sortIndex: Int
}

/// SQLite over the system libsqlite3.
///
/// Note there is no FTS5 index here, deliberately: `title` and `preview` are
/// stored sealed, and a full-text index needs plaintext to work on. Search
/// runs in memory over decrypted rows instead — at a few thousand items that
/// is a few milliseconds, and it keeps the encryption honest.
final class Store {
    struct UpsertResult {
        var id: Int64
        /// A newly written blob that was unnecessary because the row already
        /// existed. The caller owns the filesystem and must remove it.
        var discardedBlobPath: String?
    }

    enum Failure: Error {
        case open(String)
        case sql(String)
    }

    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure.open(lastError)
        }

        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try migrate()

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS pinboards (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                name          TEXT    NOT NULL,
                color         TEXT    NOT NULL DEFAULT '#5B8DEF',
                requires_auth INTEGER NOT NULL DEFAULT 0,
                sort_index    INTEGER NOT NULL DEFAULT 0
            )
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS items (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                kind             TEXT    NOT NULL,
                title            BLOB,
                preview          BLOB,
                fingerprint      TEXT    NOT NULL,
                blob_path        TEXT,
                byte_size        INTEGER NOT NULL DEFAULT 0,
                char_count       INTEGER NOT NULL DEFAULT 0,
                source_bundle_id TEXT,
                source_name      TEXT,
                created_at       REAL    NOT NULL,
                last_used_at     REAL,
                pinboard_id      INTEGER REFERENCES pinboards(id) ON DELETE SET NULL,
                sort_index       REAL    NOT NULL DEFAULT 0,
                title_is_custom  INTEGER NOT NULL DEFAULT 0,
                link_title       BLOB,
                link_image_path  TEXT,
                link_domain      BLOB
            )
            """)

        // Added after the first release: separates a name the user typed from the
        // one derived at capture. Paste imports may already carry custom names,
        // so the versioned backfill below identifies those before the UI relies
        // on this flag.
        if try !columnExists("title_is_custom", in: "items") {
            try exec("ALTER TABLE items ADD COLUMN title_is_custom INTEGER NOT NULL DEFAULT 0")
        }
        if try !columnExists("link_title", in: "items") {
            try exec("ALTER TABLE items ADD COLUMN link_title BLOB")
        }
        if try !columnExists("link_image_path", in: "items") {
            try exec("ALTER TABLE items ADD COLUMN link_image_path TEXT")
        }
        if try !columnExists("link_domain", in: "items") {
            try exec("ALTER TABLE items ADD COLUMN link_domain BLOB")
        }

        // Same content copied twice lands on the same row, per pinboard.
        try exec("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_items_fingerprint
                ON items(fingerprint, IFNULL(pinboard_id, 0))
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC)")
        try exec("CREATE INDEX IF NOT EXISTS idx_items_pinboard ON items(pinboard_id, sort_index)")

        if try userVersion() < 1 {
            try backfillCustomTitles()
            try exec("PRAGMA user_version = 1")
        }
        if try userVersion() < 2 {
            try exec("PRAGMA user_version = 2")
        }
        if try userVersion() < 3 {
            try mergeUnfiledTwins()
            try exec("PRAGMA user_version = 3")
        }
    }

    /// Removes unfiled rows whose content is already filed in a pinboard.
    ///
    /// A previous build treated "use an item from a pinboard" as "copy it into
    /// the clipboard", which created a second row for the same content. Now that
    /// the clipboard view lists filed items too, those twins show up twice. The
    /// filed row wins — it is the one the user deliberately put somewhere — and
    /// it inherits the twin's recency so it lands where they expect to find it.
    private func mergeUnfiledTwins() throws {
        var twins: [(loose: Int64, filed: Int64, lastUsed: Double)] = []
        try step("""
            SELECT loose.id, filed.id, MAX(loose.created_at, IFNULL(loose.last_used_at, 0))
            FROM items AS loose
            JOIN items AS filed
              ON filed.fingerprint = loose.fingerprint AND filed.pinboard_id IS NOT NULL
            WHERE loose.pinboard_id IS NULL
            """) { stmt in
            twins.append((sqlite3_column_int64(stmt, 0),
                          sqlite3_column_int64(stmt, 1),
                          sqlite3_column_double(stmt, 2)))
        }

        for twin in twins {
            try exec("""
                UPDATE items SET last_used_at = MAX(IFNULL(last_used_at, 0), ?) WHERE id = ?
                """) { stmt in
                sqlite3_bind_double(stmt, 1, twin.lastUsed)
                sqlite3_bind_int64(stmt, 2, twin.filed)
            }
            // delete() already refuses to report a blob another row still uses,
            // so the filed row keeps its image.
            _ = try delete(id: twin.loose)
        }
    }

    private func columnExists(_ column: String, in table: String) throws -> Bool {
        var found = false
        try step("PRAGMA table_info(\(table))") { stmt in
            if Self.text(stmt, 1) == column { found = true }
        }
        return found
    }

    private func userVersion() throws -> Int {
        var version = 0
        try step("PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
        return version
    }

    /// Before `title_is_custom`, Paste names and automatically derived titles
    /// shared one column. Recover the distinction once, while both values are
    /// still available, without exposing either one outside this process.
    private func backfillCustomTitles() throws {
        var customIDs: [Int64] = []
        try step("""
            SELECT id, kind, title, preview FROM items
            WHERE title IS NOT NULL AND title_is_custom = 0
            """) { stmt in
            guard let title = try? Self.sealedString(stmt, 2),
                  let preview = try? Self.sealedString(stmt, 3)
            else { return }

            let kind = ClipKind(rawValue: Self.text(stmt, 1) ?? "") ?? .text
            if Self.isCustomTitle(title, kind: kind, preview: preview) {
                customIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }

        for id in customIDs {
            try exec("UPDATE items SET title_is_custom = 1 WHERE id = ?") {
                sqlite3_bind_int64($0, 1, id)
            }
        }
    }

    private static func isCustomTitle(_ title: String, kind: ClipKind, preview: String) -> Bool {
        switch kind {
        case .image:
            return !title.hasPrefix("Imagem")
        case .file:
            let derived = preview
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)).lastPathComponent }
                .joined(separator: ", ")
            return title != derived
        default:
            let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            let derived = trimmed.split(separator: "\n").first.map(String.init) ?? ""
            return title != derived
        }
    }

    // MARK: - Items

    /// Inserts, or bumps the timestamp if this exact content is already known.
    /// Returns the row id either way, plus any just-written blob dedupe made
    /// unnecessary.
    @discardableResult
    func upsert(_ item: ClipItem) throws -> UpsertResult {
        if let existing = try id(forFingerprint: item.fingerprint, pinboardID: item.pinboardID) {
            try exec(
                "UPDATE items SET created_at = ?, last_used_at = ? WHERE id = ?",
                bind: { stmt in
                    sqlite3_bind_double(stmt, 1, item.createdAt.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
                    sqlite3_bind_int64(stmt, 3, existing)
                }
            )
            if item.titleIsCustom, let title = item.title {
                try setTitle(id: existing, title: title)
            }
            return UpsertResult(id: existing, discardedBlobPath: item.blobPath)
        }

        let sealedTitle = try item.title.map { try Crypto.seal($0) }
        let sealedPreview = try Crypto.seal(item.preview)
        let sealedLinkTitle = try item.linkTitle.map { try Crypto.seal($0) }
        let sealedLinkDomain = try item.linkDomain.map { try Crypto.seal($0) }

        try exec("""
            INSERT INTO items
                (kind, title, preview, fingerprint, blob_path, byte_size, char_count,
                 source_bundle_id, source_name, created_at, last_used_at, pinboard_id, sort_index,
                 title_is_custom, link_title, link_image_path, link_domain)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, bind: { stmt in
                sqlite3_bind_text(stmt, 1, item.kind.rawValue, -1, SQLITE_TRANSIENT)
                Self.bind(stmt, 2, blob: sealedTitle)
                Self.bind(stmt, 3, blob: sealedPreview)
                sqlite3_bind_text(stmt, 4, item.fingerprint, -1, SQLITE_TRANSIENT)
                Self.bind(stmt, 5, text: item.blobPath)
                sqlite3_bind_int64(stmt, 6, Int64(item.byteSize))
                sqlite3_bind_int64(stmt, 7, Int64(item.charCount))
                Self.bind(stmt, 8, text: item.sourceBundleID)
                Self.bind(stmt, 9, text: item.sourceName)
                sqlite3_bind_double(stmt, 10, item.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 11, (item.lastUsedAt ?? item.createdAt).timeIntervalSinceReferenceDate)
                if let pinboardID = item.pinboardID {
                    sqlite3_bind_int64(stmt, 12, pinboardID)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                sqlite3_bind_double(stmt, 13, 0)
                sqlite3_bind_int(stmt, 14, item.titleIsCustom ? 1 : 0)
                Self.bind(stmt, 15, blob: sealedLinkTitle)
                Self.bind(stmt, 16, text: item.linkImagePath)
                Self.bind(stmt, 17, blob: sealedLinkDomain)
            })

        return UpsertResult(id: sqlite3_last_insert_rowid(db), discardedBlobPath: nil)
    }

    /// `pinboardID: nil` is not "the unfiled bucket" — it is **everything**, filed
    /// or not, most recently touched first. A pinboard is a filter over that same
    /// set, kept in the order the user arranged by hand.
    ///
    /// This is why using something out of a pinboard doesn't need to copy it
    /// anywhere: it already appears in the clipboard view, and touching it just
    /// floats it up. An earlier version created a second row for that, which put
    /// the same content on screen twice.
    func items(pinboardID: Int64?, limit: Int = 500) throws -> [ClipItem] {
        let filter = pinboardID == nil ? "1 = 1" : "pinboard_id = ?"
        let order = pinboardID == nil
            ? "MAX(created_at, IFNULL(last_used_at, created_at)) DESC"
            : "sort_index ASC, created_at DESC"

        return try query("""
            SELECT id, kind, title, preview, fingerprint, blob_path, byte_size, char_count,
                   source_bundle_id, source_name, created_at, last_used_at, pinboard_id,
                   title_is_custom, link_title, link_image_path, link_domain
            FROM items WHERE \(filter) ORDER BY \(order) LIMIT ?
            """, bind: { stmt in
                if let pinboardID {
                    sqlite3_bind_int64(stmt, 1, pinboardID)
                    sqlite3_bind_int64(stmt, 2, Int64(limit))
                } else {
                    sqlite3_bind_int64(stmt, 1, Int64(limit))
                }
            })
    }

    /// A name you give an item, so search can find it by what it is
    /// ("contrato modelo") rather than by what it contains.
    /// Clearing the name puts the card back to showing its type label.
    func setTitle(id: Int64, title: String) throws {
        let sealed = title.isEmpty ? nil : try Crypto.seal(title)
        try exec("UPDATE items SET title = ?, title_is_custom = ? WHERE id = ?") { stmt in
            Self.bind(stmt, 1, blob: sealed)
            sqlite3_bind_int(stmt, 2, title.isEmpty ? 0 : 1)
            sqlite3_bind_int64(stmt, 3, id)
        }
    }

    /// Every item, whichever pinboard it sits in. Backs global search: you
    /// rarely remember which board you filed something in.
    /// Everything, in the same order the clipboard tab uses.
    ///
    /// Same order deliberately: this backs the global search, and ordering it by
    /// `created_at` alone put an old item you used this morning at the top of the
    /// tab and near the bottom of the search for the very same word.
    func allItems(limit: Int = 5000) throws -> [ClipItem] {
        try query("""
            SELECT id, kind, title, preview, fingerprint, blob_path, byte_size, char_count,
                   source_bundle_id, source_name, created_at, last_used_at, pinboard_id,
                   title_is_custom, link_title, link_image_path, link_domain
            FROM items
            ORDER BY MAX(created_at, IFNULL(last_used_at, created_at)) DESC
            LIMIT ?
            """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) })
    }

    /// Marks an item as just used, which is what floats it to the top of the
    /// clipboard view. No copy and no new row — the item stays exactly where it
    /// is, including inside whatever pinboard it belongs to.
    func touch(id: Int64) throws {
        try exec("UPDATE items SET last_used_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 2, id)
        }
    }

    /// Returns every blob path the row owned. Deleting the row alone would leave
    /// encrypted image files behind on disk forever.
    @discardableResult
    func delete(id: Int64) throws -> [String] {
        var paths: [String] = []
        try step("SELECT blob_path, link_image_path FROM items WHERE id = ?",
                 bind: { sqlite3_bind_int64($0, 1, id) },
                 row: { stmt in
                     if let path = Self.text(stmt, 0) { paths.append(path) }
                     if let path = Self.text(stmt, 1) { paths.append(path) }
                 })
        try exec("DELETE FROM items WHERE id = ?") { sqlite3_bind_int64($0, 1, id) }
        return try orphaned(paths)
    }

    /// Moves an item, merging it when the destination already holds the same
    /// fingerprint. Returns source blobs that became orphaned after a merge.
    @discardableResult
    func move(id: Int64, toPinboard pinboardID: Int64?) throws -> [String] {
        var fingerprint: String?
        try step("SELECT fingerprint FROM items WHERE id = ?",
                 bind: { sqlite3_bind_int64($0, 1, id) },
                 row: { fingerprint = Self.text($0, 0) })
        guard let fingerprint else { return [] }

        if let existing = try self.id(forFingerprint: fingerprint, pinboardID: pinboardID),
           existing != id {
            return try delete(id: id)
        }

        try exec("UPDATE items SET pinboard_id = ? WHERE id = ?") { stmt in
            if let pinboardID { sqlite3_bind_int64(stmt, 1, pinboardID) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int64(stmt, 2, id)
        }
        return []
    }

    func needsLinkMetadata(id: Int64) throws -> Bool {
        var missing = false
        try step("SELECT link_title, link_image_path FROM items WHERE id = ?",
                 bind: { sqlite3_bind_int64($0, 1, id) },
                 row: { stmt in
                     missing = sqlite3_column_type(stmt, 0) == SQLITE_NULL
                         && sqlite3_column_type(stmt, 1) == SQLITE_NULL
                 })
        return missing
    }

    /// Returns the previous preview image so a refresh can remove it after the
    /// row safely points at the replacement.
    @discardableResult
    func setLinkMetadata(id: Int64, title: String?, imagePath: String?, domain: String?) throws -> String? {
        var previousImage: String?
        var exists = false
        try step("SELECT link_image_path FROM items WHERE id = ?",
                 bind: { sqlite3_bind_int64($0, 1, id) },
                 row: { stmt in
                     exists = true
                     previousImage = Self.text(stmt, 0)
                 })
        guard exists else { throw Failure.sql("link item no longer exists") }

        let sealedTitle = try title.map { try Crypto.seal($0) }
        let sealedDomain = try domain.map { try Crypto.seal($0) }
        try exec("""
            UPDATE items SET link_title = ?, link_image_path = ?, link_domain = ? WHERE id = ?
            """) { stmt in
            Self.bind(stmt, 1, blob: sealedTitle)
            Self.bind(stmt, 2, text: imagePath)
            Self.bind(stmt, 3, blob: sealedDomain)
            sqlite3_bind_int64(stmt, 4, id)
        }
        guard let previousImage, previousImage != imagePath else { return nil }
        return try orphaned([previousImage]).first
    }

    /// Loose history only: pinned items are never swept.
    /// Every blob path any row still points at. What is on disk and not in here
    /// is dead weight — see `BlobStore.sweepOrphans`.
    func referencedBlobPaths() throws -> Set<String> {
        var paths: Set<String> = []
        try step("SELECT blob_path, link_image_path FROM items", row: { stmt in
            if let path = Self.text(stmt, 0) { paths.insert(path) }
            if let path = Self.text(stmt, 1) { paths.insert(path) }
        })
        return paths
    }

    func looseItemCount() throws -> Int {
        var total = 0
        try step("SELECT COUNT(*) FROM items WHERE pinboard_id IS NULL") {
            total = Int(sqlite3_column_int64($0, 0))
        }
        return total
    }

    @discardableResult
    func pruneHistory(keeping maximum: Int) throws -> [String] {
        let condition = """
            pinboard_id IS NULL AND id NOT IN (
                SELECT id FROM items WHERE pinboard_id IS NULL
                ORDER BY created_at DESC LIMIT ?
            )
            """
        return try prune(where: condition) { sqlite3_bind_int64($0, 1, Int64(maximum)) }
    }

    /// Drops loose items older than `days`. Zero means "keep forever".
    @discardableResult
    func pruneHistory(olderThanDays days: Int) throws -> [String] {
        guard days > 0 else { return [] }
        let cutoff = Date()
            .addingTimeInterval(-Double(days) * 86_400)
            .timeIntervalSinceReferenceDate
        return try prune(where: "pinboard_id IS NULL AND created_at < ?") {
            sqlite3_bind_double($0, 1, cutoff)
        }
    }

    /// Everything not filed in a pinboard. Pinboards survive on purpose.
    @discardableResult
    func clearLooseHistory() throws -> [String] {
        try prune(where: "pinboard_id IS NULL") { _ in }
    }

    /// Collects the blob paths first, then deletes: once the rows are gone there
    /// is no way to find which files they owned.
    private func prune(where condition: String,
                       bind: @escaping (OpaquePointer?) -> Void) throws -> [String] {
        var orphans: [String] = []
        try step("SELECT blob_path, link_image_path FROM items WHERE \(condition)",
                 bind: bind,
                 row: { stmt in
                     if let path = Self.text(stmt, 0) { orphans.append(path) }
                     if let path = Self.text(stmt, 1) { orphans.append(path) }
                 })
        try exec("DELETE FROM items WHERE \(condition)", bind: bind)
        return try orphaned(orphans)
    }

    /// Drops paths another row still points at.
    ///
    /// Rows can share an encrypted file: using an item out of a pinboard leaves
    /// a copy in the loose history pointing at the same blob. Deleting either row
    /// must not delete the file the other one still draws from. Called *after*
    /// the DELETE, so the row being removed no longer counts as a reference.
    private func orphaned(_ paths: [String]) throws -> [String] {
        var result: [String] = []
        for path in Set(paths) {
            var references = 0
            try step("SELECT COUNT(*) FROM items WHERE blob_path = ? OR link_image_path = ?",
                     bind: { stmt in
                         sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                         sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
                     },
                     row: { references = Int(sqlite3_column_int64($0, 0)) })
            if references == 0 { result.append(path) }
        }
        return result
    }

    // MARK: - Pinboards

    func pinboards() throws -> [Pinboard] {
        var result: [Pinboard] = []
        try step("SELECT id, name, color, requires_auth, sort_index FROM pinboards ORDER BY sort_index, id") { stmt in
            result.append(Pinboard(
                id: sqlite3_column_int64(stmt, 0),
                name: Self.text(stmt, 1) ?? "",
                color: Self.text(stmt, 2) ?? "#5B8DEF",
                requiresAuth: sqlite3_column_int(stmt, 3) != 0,
                sortIndex: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return result
    }

    func setPinboardColor(id: Int64, color: String) throws {
        try exec("UPDATE pinboards SET color = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, color, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
        }
    }

    func createPinboard(name: String, color: String, sortIndex: Int) throws -> Int64 {
        try exec("INSERT INTO pinboards (name, color, sort_index) VALUES (?,?,?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, color, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(sortIndex))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func renamePinboard(id: Int64, name: String) throws {
        try exec("UPDATE pinboards SET name = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
        }
    }

    /// Deleting a folder keeps its contents by moving them to loose history.
    /// Duplicate contents merge under the same rule as an explicit item move.
    @discardableResult
    func deletePinboard(id: Int64) throws -> [String] {
        var itemIDs: [Int64] = []
        try step("SELECT id FROM items WHERE pinboard_id = ?",
                 bind: { sqlite3_bind_int64($0, 1, id) },
                 row: { itemIDs.append(sqlite3_column_int64($0, 0)) })

        var orphans: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for itemID in itemIDs { orphans += try move(id: itemID, toPinboard: nil) }
            try exec("DELETE FROM pinboards WHERE id = ?") { sqlite3_bind_int64($0, 1, id) }
            try exec("COMMIT")
            return orphans
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Rewrites the stable order after a drag. One transaction prevents a
    /// partially ordered pinboard if any statement fails.
    func setItemOrder(_ ids: [Int64], pinboardID: Int64) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for (position, id) in ids.enumerated() {
                try exec("UPDATE items SET sort_index = ? WHERE id = ? AND pinboard_id = ?") { stmt in
                    sqlite3_bind_double(stmt, 1, Double(position))
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_bind_int64(stmt, 3, pinboardID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func count(table: String) throws -> Int {
        var total = 0
        try step("SELECT COUNT(*) FROM \(table)") { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    // MARK: - Plumbing

    private func id(forFingerprint fingerprint: String, pinboardID: Int64?) throws -> Int64? {
        var found: Int64?
        // A capture (pinboardID nil) matches the content *anywhere*. Copying
        // something that is already filed has to bump that row, not create an
        // unfiled twin — the clipboard view shows filed items too, so a twin
        // would simply appear on screen twice. Preferring the unfiled row keeps
        // pre-existing databases stable.
        let filter = pinboardID == nil ? "1 = 1" : "pinboard_id = ?"
        let order = pinboardID == nil ? " ORDER BY pinboard_id IS NULL DESC, id ASC" : ""
        try step("SELECT id FROM items WHERE fingerprint = ? AND \(filter)\(order)", bind: { stmt in
            sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
            if let pinboardID { sqlite3_bind_int64(stmt, 2, pinboardID) }
        }, row: { if found == nil { found = sqlite3_column_int64($0, 0) } })
        return found
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) throws -> [ClipItem] {
        var result: [ClipItem] = []
        try step(sql, bind: bind) { stmt in
            // A row we cannot decrypt is a row written under a lost key; skip it
            // rather than taking the whole list down.
            guard let preview = try? Self.sealedString(stmt, 3) else { return }
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: ClipKind(rawValue: Self.text(stmt, 1) ?? "") ?? .text,
                title: try? Self.sealedString(stmt, 2),
                preview: preview,
                fingerprint: Self.text(stmt, 4) ?? "",
                blobPath: Self.text(stmt, 5),
                byteSize: Int(sqlite3_column_int64(stmt, 6)),
                charCount: Int(sqlite3_column_int64(stmt, 7)),
                sourceBundleID: Self.text(stmt, 8),
                sourceName: Self.text(stmt, 9),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10)),
                lastUsedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11)),
                pinboardID: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 12),
                titleIsCustom: sqlite3_column_int(stmt, 13) != 0,
                linkTitle: try? Self.sealedString(stmt, 14),
                linkImagePath: Self.text(stmt, 15),
                linkDomain: try? Self.sealedString(stmt, 16)
            ))
        }
        return result
    }

    private func exec(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        try step(sql, bind: bind ?? { _ in }, row: nil)
    }

    private func step(_ sql: String,
                      bind: (OpaquePointer?) -> Void = { _ in },
                      row: ((OpaquePointer?) -> Void)?) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.sql("\(lastError) — \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)

        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let row { row(stmt) } else { return }
            case SQLITE_DONE:
                return
            default:
                throw Failure.sql("\(lastError) — \(sql)")
            }
        }
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }

    private static func sealedString(_ stmt: OpaquePointer?, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_blob(stmt, column) else { throw Failure.sql("null blob") }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return try Crypto.openString(Data(bytes: bytes, count: count))
    }

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, text: String?) {
        if let text {
            sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, blob: Data?) {
        guard let blob else { sqlite3_bind_null(stmt, index); return }
        _ = blob.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }
}
