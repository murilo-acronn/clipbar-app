import AppKit

/// Integrity pass over everything in the store: decrypt each row, decode each
/// blob, and report anything that doesn't come back intact.
///
/// It never prints item content. It used to print a 52-character sample for
/// every pinboard whose *name* didn't look like it held credentials — which
/// meant the guarantee rested on a word list, and a pinboard called "Trabalho"
/// with a token in it printed the token. It also meant the source carried a
/// hardcoded list of the words this user files secrets under.
///
/// Shape is enough to verify integrity. If you ever need to eyeball actual
/// contents again, that is what the app itself is for.
enum Verify {
    static func run() throws {
        let store = try Store(url: Paths.database)
        let blobs = try BlobStore(root: Paths.blobs)
        let boards = try store.pinboards()

        var checked = 0, badText = 0, badBlob = 0

        // Every row exactly once. `items(pinboardID: nil)` is the *whole*
        // collection now, filed rows included, so listing it alongside each
        // pinboard would check — and count — filed items twice.
        let everything = try store.allItems()
        // allItems skips rows that fail to decrypt, so iterating it alone would
        // report "tudo íntegro" over a database whose rows are hidden — the one
        // case where this command matters most.
        let hidden = try store.count(table: "items") - everything.count
        let unfiled = everything.filter { $0.pinboardID == nil }

        for board in [nil] + boards.map(Optional.init) {
            let name = board?.name ?? "(sem pasta)"
            let items = board.map { current in everything.filter { $0.pinboardID == current.id } } ?? unfiled

            print("\n\(name) — \(items.count) itens")

            for item in items {
                checked += 1

                if item.preview.isEmpty { badText += 1; print("  ⚠️ preview vazio (id \(item.id ?? -1))") }

                if let path = item.blobPath {
                    guard let data = try? blobs.read(path), NSImage(data: data) != nil else {
                        badBlob += 1
                        print("  ❌ blob ilegível: \(path)")
                        continue
                    }
                }

                print("  · [\(item.kind.rawValue)] \(describe(item))")
            }
        }

        if hidden > 0 {
            print("\n❌ \(hidden) linhas existem no banco mas não decifram com a chave atual — não aparecem no app")
        }

        print("""

        ── integridade ──
        \(checked) itens verificados
        \(badText) previews vazios · \(badBlob) blobs ilegíveis · \(hidden) linhas que não decifram
        \(badText == 0 && badBlob == 0 && hidden == 0 ? "✅ tudo íntegro" : "⚠️ há problemas acima")
        """)
    }

    /// Enough to tell rows apart and spot a broken one; nothing that could be
    /// read back as the item itself.
    private static func describe(_ item: ClipItem) -> String {
        var parts = ["id \(item.id ?? -1)", "\(item.charCount) caracteres"]
        if item.titleIsCustom { parts.append("nome próprio") }
        if item.blobPath != nil { parts.append("blob ok") }
        if item.linkImagePath != nil { parts.append("prévia de link") }
        if let source = item.sourceName { parts.append("de \(source)") }
        return parts.joined(separator: " · ")
    }
}
