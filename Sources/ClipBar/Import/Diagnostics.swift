import AppKit

enum Diagnostics {
    private enum SelfTestFailure: Error {
        case assertion(String)
    }

    /// Reports why auto-paste might not be firing, and how search sees an item.
    static func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        print("""
        Acessibilidade (colar automático): \(trusted ? "✅ autorizado" : "❌ NÃO autorizado")
        Colar automático nas preferências: \(Preferences.autoPasteEnabled ? "ligado" : "desligado")
        Binário: \(Bundle.main.bundlePath)
        """)

        if !trusted {
            print("""

            ⚠️  ESTE "NÃO" NÃO É CONFIÁVEL quando o --check roda pelo terminal.

            AXIsProcessTrusted() responde pelo processo que chama, e o macOS
            atribui a confiança de Acessibilidade ao *responsible process* — ao
            rodar o binário de dentro do bundle pela linha de comando, quem
            responde é o terminal, não o ClipBar.app. Já aconteceu de o app
            estar autorizado e colar normalmente com este aviso na tela.

            O TESTE QUE VALE é o próprio app: abra a barra com ⌘⌥V sobre um
            campo de texto e aperte ⏎.
              · colou            → está autorizado; ignore o que está acima
              · surgiu um alerta pedindo Acessibilidade → aí sim falta permissão
              · nem colou nem alertou → é bug no disparo, não permissão

            Se realmente faltar permissão: Ajustes do Sistema › Privacidade e
            Segurança › Acessibilidade. Se "ClipBar" já estiver lá, desligar e
            ligar o botão NÃO resolve — a entrada segue presa à assinatura de um
            build antigo. Remova com − (a linha tem que sumir) e adicione de novo
            com +, apontando para /Applications/ClipBar.app — nunca para build/,
            que é sobrescrito a cada compilação.
            """)
        }
    }

    /// Searches the way the bar does, reporting where hits live without
    /// printing the contents — these pinboards hold credentials.
    static func find(_ query: String) throws {
        let store = try Store(url: Paths.database)
        let boards = try store.pinboards()
        let items = try store.allItems()

        let terms = query.lowercased().split(separator: " ").map {
            String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }

        print("Buscando \(terms) em \(items.count) itens\n")
        var hits = 0

        for item in items {
            let title = item.title ?? ""
            let inTitle = terms.allSatisfy {
                title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains($0)
            }
            let inPreview = terms.allSatisfy {
                item.preview.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains($0)
            }
            guard inTitle || inPreview else { continue }

            hits += 1
            let board = boards.first { $0.id == item.pinboardID }?.name ?? "(histórico solto)"
            print("  ✓ pasta \(board) · casou em \(inTitle ? "TÍTULO" : "conteúdo") · \(item.kind.rawValue)")
        }

        if hits == 0 {
            print("Nenhum resultado.\n")
            print("Títulos existentes por pasta (só o comprimento, sem revelar o conteúdo):")
            for board in boards {
                let boardItems = items.filter { $0.pinboardID == board.id }
                let named = boardItems.filter { ($0.title?.count ?? 0) > 0 }.count
                print("  \(board.name): \(boardItems.count) itens, \(named) com título")
            }
        } else {
            print("\n\(hits) resultado(s).")
        }
    }

    /// Exercises schema creation, encrypted round-trips, dedupe-on-move, link
    /// metadata and ordering in an isolated temporary store. No real clipboard
    /// content or production database is opened.
    static func selfTest() throws {
        Crypto.useEphemeralKeyForSelfTest()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipbar-self-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runSelfTest(in: root)
        print("✅ store, criptografia, merge, links e ordenação")
    }

    private static func runSelfTest(in root: URL) throws {
        let store = try Store(url: root.appending(path: "test.sqlite"))
        let blobs = try BlobStore(root: root.appending(path: "blobs"))
        let boardA = try store.createPinboard(name: "A", color: "#3366FF", sortIndex: 0)
        let boardB = try store.createPinboard(name: "B", color: "#6633FF", sortIndex: 1)

        func textItem(_ text: String, pinboardID: Int64?, title: String? = nil) throws -> ClipItem {
            ClipItem(
                id: nil,
                kind: ClipKind.infer(fromText: text),
                title: title ?? text,
                preview: text,
                fingerprint: try Crypto.fingerprint(Data(text.utf8)),
                blobPath: nil,
                byteSize: text.utf8.count,
                charCount: text.count,
                sourceBundleID: "io.local.clipbar.self-test",
                sourceName: "Self Test",
                createdAt: Date(),
                lastUsedAt: Date(),
                pinboardID: pinboardID,
                titleIsCustom: title != nil
            )
        }

        let duplicateA = try store.upsert(textItem("same", pinboardID: boardA)).id
        _ = try store.upsert(textItem("same", pinboardID: boardB))
        let orphans = try store.move(id: duplicateA, toPinboard: boardB)
        for orphan in orphans { blobs.delete(orphan) }
        guard try store.items(pinboardID: boardB).filter({ $0.preview == "same" }).count == 1 else {
            throw SelfTestFailure.assertion("merge de duplicata")
        }

        let link = try store.upsert(textItem("https://example.com", pinboardID: nil)).id
        _ = try store.setLinkMetadata(id: link, title: "Example", imagePath: nil, domain: "example.com")
        guard let loadedLink = try store.items(pinboardID: nil).first(where: { $0.id == link }),
              loadedLink.linkTitle == "Example", loadedLink.linkDomain == "example.com" else {
            throw SelfTestFailure.assertion("metadados de link")
        }

        let first = try store.upsert(textItem("first", pinboardID: boardB)).id
        let second = try store.upsert(textItem("second", pinboardID: boardB)).id
        try store.setItemOrder([second, first], pinboardID: boardB)
        let ordered = try store.items(pinboardID: boardB).filter { $0.id == first || $0.id == second }
        guard ordered.map(\.id) == [second, first] else {
            throw SelfTestFailure.assertion("ordenação")
        }

        let disposable = try store.createPinboard(name: "C", color: "#999999", sortIndex: 2)
        let preserved = try store.upsert(textItem("preserved", pinboardID: disposable)).id
        for orphan in try store.deletePinboard(id: disposable) { blobs.delete(orphan) }
        guard try store.items(pinboardID: nil).contains(where: { $0.id == preserved }) else {
            throw SelfTestFailure.assertion("exclusão de pasta preserva itens")
        }

        try checkUseSurfacesInHistory(store: store, pinboardID: boardA)
        try checkSharedBlobSurvivesOneDelete(store: store, blobs: blobs, pinboardID: boardA)
    }

    /// Using a filed item must surface it in recents *and* leave it filed.
    private static func checkUseSurfacesInHistory(store: Store, pinboardID: Int64) throws {
        let text = "usado a partir da pasta"
        let filed = ClipItem(
            id: nil, kind: .text, title: nil, preview: text,
            fingerprint: try Crypto.fingerprint(Data(text.utf8)),
            blobPath: nil, byteSize: text.utf8.count, charCount: text.count,
            sourceBundleID: "io.local.clipbar.self-test", sourceName: "Self Test",
            createdAt: Date(), lastUsedAt: Date(), pinboardID: pinboardID
        )
        let filedID = try store.upsert(filed).id

        var copy = filed
        copy.id = nil
        copy.pinboardID = nil
        copy.createdAt = Date()
        _ = try store.upsert(copy)

        guard try store.items(pinboardID: pinboardID).contains(where: { $0.id == filedID }) else {
            throw SelfTestFailure.assertion("usar item da pasta não pode tirá-lo da pasta")
        }
        guard try store.items(pinboardID: nil).contains(where: { $0.preview == text }) else {
            throw SelfTestFailure.assertion("usar item da pasta deve fazê-lo aparecer nos recentes")
        }
    }

    /// Two rows sharing one encrypted blob: deleting the first must not report
    /// the file as orphaned, deleting the second must.
    private static func checkSharedBlobSurvivesOneDelete(store: Store, blobs: BlobStore,
                                                         pinboardID: Int64) throws {
        let payload = Data("imagem compartilhada".utf8)
        let path = try blobs.write(payload, extension: "png")
        let label = "Imagem 10×10"

        func imageRow(pinboardID: Int64?) throws -> ClipItem {
            ClipItem(
                id: nil, kind: .image, title: label, preview: label,
                fingerprint: try Crypto.fingerprint(payload),
                blobPath: path, byteSize: payload.count, charCount: label.count,
                sourceBundleID: "io.local.clipbar.self-test", sourceName: "Self Test",
                createdAt: Date(), lastUsedAt: Date(), pinboardID: pinboardID
            )
        }

        let filedID = try store.upsert(imageRow(pinboardID: pinboardID)).id
        let looseID = try store.upsert(imageRow(pinboardID: nil)).id

        guard try store.delete(id: looseID).isEmpty else {
            throw SelfTestFailure.assertion("blob ainda referenciado não pode ser apagado")
        }
        guard (try? blobs.read(path)) != nil else {
            throw SelfTestFailure.assertion("blob compartilhado sumiu cedo demais")
        }
        guard try store.delete(id: filedID) == [path] else {
            throw SelfTestFailure.assertion("último dono do blob deve liberá-lo")
        }
    }
}
