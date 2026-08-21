import AppKit

/// Integrity pass over everything in the store: decrypt each row, decode each
/// blob, and report anything that doesn't come back intact.
///
/// Previews are printed only for pinboards that aren't holding credentials —
/// a migration check shouldn't spray secrets across a terminal.
enum Verify {
    /// Pinboards whose contents are never printed, matched case-insensitively and
    /// without accents. A heuristic, not a guarantee — it only decides what this
    /// diagnostic is willing to echo, and it errs towards staying quiet.
    /// Folded before comparing so CARTÕES, Cartoes and cartões all match.
    private static func isSensitive(_ name: String) -> Bool {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: nil)
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { sensitiveNames.contains(String($0)) }
    }

    private static let sensitiveNames: Set<String> = [
        "senhas", "senha", "passwords", "password",
        "chaves", "chave", "keys", "key",
        "tokens", "token", "secrets", "secret",
        "cartoes", "cartao", "cards", "card",
        "pix", "bancos", "banco", "credenciais", "credentials",
    ]

    static func run() throws {
        let store = try Store(url: Paths.database)
        let blobs = try BlobStore(root: Paths.blobs)
        let boards = try store.pinboards()

        var checked = 0, badText = 0, badBlob = 0

        // Every row exactly once. `items(pinboardID: nil)` is the *whole*
        // collection now, filed rows included, so listing it alongside each
        // pinboard would check — and count — filed items twice.
        let everything = try store.allItems()
        let unfiled = everything.filter { $0.pinboardID == nil }

        for board in [nil] + boards.map(Optional.init) {
            let name = board?.name ?? "(sem pasta)"
            let items = board.map { current in everything.filter { $0.pinboardID == current.id } } ?? unfiled
            let hidden = board.map { isSensitive($0.name) } ?? false

            print("\n\(name) — \(items.count) itens\(hidden ? "  [conteúdo omitido]" : "")")

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

                guard !hidden else { continue }
                let sample = item.preview
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(52)
                print("  · [\(item.kind.rawValue)] \(sample)\(item.preview.count > 52 ? "…" : "")")
            }
        }

        print("""

        ── integridade ──
        \(checked) itens verificados
        \(badText) previews vazios · \(badBlob) blobs ilegíveis
        \(badText == 0 && badBlob == 0 ? "✅ tudo íntegro" : "⚠️ há problemas acima")
        """)
    }
}
