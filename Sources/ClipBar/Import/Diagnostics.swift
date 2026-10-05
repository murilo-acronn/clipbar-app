import AppKit

enum Diagnostics {
    private enum SelfTestFailure: Error {
        case assertion(String)
    }

    /// What the running app knows about its own shortcut, in the words the user
    /// will need when the bar "stops opening".
    ///
    /// Written to be read at the moment of failure, from the menu bar, which is
    /// the one part of the app that keeps working when the shortcut does not.
    /// Every line here answers a question that otherwise costs a whole session:
    /// whether the key is even reaching the process, and whether something else
    /// on the system is holding the keyboard.
    static func hotKeyReport() -> String {
        let fired: String
        if let last = HotKey.lastFiredAt {
            let seconds = Int(Date().timeIntervalSince(last))
            fired = seconds < 60 ? "há \(seconds)s" : "há \(seconds / 60) min"
        } else {
            fired = "nunca, desde que o app abriu"
        }

        return """
        Atalho configurado: \(Preferences.hotKeyLabel)
        Registro no sistema: \(HotKey.lastRegistrationSucceeded ? "aceito" : "RECUSADO")
        A tecla chegou no ClipBar: \(fired)
        Entrada segura do teclado: \(HotKey.secureInputIsActive ? "ATIVA" : "desligada")
        Acessibilidade (colar sozinho): \(AXIsProcessTrusted() ? "autorizada" : "não autorizada")
        """
    }

    /// The part of the report that only means something when it is bad.
    static func hotKeyAdvice() -> String {
        if HotKey.secureInputIsActive {
            return """
            Algum app está com a entrada segura do teclado ligada, e enquanto \
            estiver o macOS não entrega atalhos globais a mais ninguém — o ClipBar \
            inclusive. Costuma ser um campo de senha aberto, ou um Terminal com \
            "Entrada Segura no Teclado" marcada no menu. Feche esse campo ou \
            desmarque a opção; o atalho volta sozinho.
            """
        }
        if HotKey.lastFiredAt == nil {
            return """
            A tecla nunca chegou até aqui. Ou outro app está capturando a mesma \
            combinação — o macOS deixa dois apps registrarem a mesma tecla e \
            entrega só para um —, ou ela simplesmente não foi apertada ainda. \
            Teste agora: se a barra não abrir e esta linha continuar igual, é \
            conflito, e o caminho é escolher outra combinação nas Preferências.
            """
        }
        return """
        A tecla está chegando. Se mesmo assim a barra não aparece, o problema é \
        na exibição do painel e não no atalho — o rastro completo sai com \
        log stream --predicate 'subsystem == "io.local.clipbar"'.
        """
    }

    /// Reports why auto-paste might not be firing, and how search sees an item.
    static func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        print("""
        Acessibilidade (colar automático): \(trusted ? "✅ autorizado" : "❌ NÃO autorizado")
        Colar automático nas preferências: \(Preferences.autoPasteEnabled ? "ligado" : "desligado")
        Entrada segura do teclado: \(HotKey.secureInputIsActive ? "⚠️ ATIVA — nenhum atalho global é entregue" : "desligada")
        Binário: \(Bundle.main.bundlePath)

        Sobre o atalho, este comando não tem o que dizer: ele roda num processo
        novo, que não registrou atalho nenhum. Quem sabe se a tecla está chegando
        é o app que está aberto — menu do ClipBar › "Diagnóstico do atalho…".
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

        try checkLinkPreviewsRefuseCredentials()
        try checkClipboardViewShowsEverything(store: store, pinboardID: boardA)
        try checkSharedBlobSurvivesOneDelete(store: store, blobs: blobs, pinboardID: boardA)
        try checkRetentionSparesRecentlyTouched(store: store, pinboardID: boardA)

        // Reopening a database that has rows must forbid minting a new key: a
        // fresh key there would silently orphan every row already sealed.
        _ = try Store(url: root.appending(path: "test.sqlite"))
        guard !Crypto.allowsKeyCreation else {
            throw SelfTestFailure.assertion("banco com itens não pode autorizar chave nova")
        }
    }

    /// Retention must count from the last time an item was used or taken out of
    /// a folder, not from when it was first copied. Both failures were silent
    /// and permanent: filed items deleted within an hour of a folder deletion.
    private static func checkRetentionSparesRecentlyTouched(store: Store, pinboardID: Int64) throws {
        func old(_ text: String, pinboardID: Int64?) throws -> ClipItem {
            let longAgo = Date(timeIntervalSinceNow: -400 * 86_400)
            return ClipItem(
                id: nil, kind: .text, title: nil, preview: text,
                fingerprint: try Crypto.fingerprint(Data(text.utf8)),
                blobPath: nil, byteSize: text.utf8.count, charCount: text.count,
                sourceBundleID: "io.local.clipbar.self-test", sourceName: "Self Test",
                createdAt: longAgo, lastUsedAt: longAgo, pinboardID: pinboardID
            )
        }

        let unfiled = try store.upsert(old("tirado da pasta", pinboardID: pinboardID)).id
        _ = try store.move(id: unfiled, toPinboard: nil)
        let used = try store.upsert(old("usado hoje", pinboardID: nil)).id
        try store.touch(id: used)
        let stale = try store.upsert(old("esquecido", pinboardID: nil)).id

        _ = try store.pruneHistory(olderThanDays: 7)
        let left = Set(try store.allItems().compactMap(\.id))
        guard left.contains(unfiled) else {
            throw SelfTestFailure.assertion("item tirado da pasta não pode expirar na hora")
        }
        guard left.contains(used) else {
            throw SelfTestFailure.assertion("item usado hoje não pode expirar")
        }
        guard !left.contains(stale) else {
            throw SelfTestFailure.assertion("item velho e sem uso deve expirar")
        }
    }

    /// The clipboard view lists filed items too, copying already-filed content
    /// must not create a twin, and using something must float it to the top.
    /// The failure this guards against is silent and permanent — a preview GET
    /// spending a one-time link — so both directions are pinned down here.
    private static func checkLinkPreviewsRefuseCredentials() throws {
        let refused = [
            "https://app.exemplo.com/login?token=aGVsbG8td29ybGQtdGhpcy1pcy1sb25n",
            "https://exemplo.com/reset/9f3c1d2e4b5a6c7d8e9f0a1b2c3d4e5f",
            "https://exemplo.com/convite?code=abc123",
            "https://user:senha@exemplo.com/",
            "https://exemplo.com/entrar#access_token=abc",
        ]
        for raw in refused {
            guard let url = URL(string: raw), LinkPreviewService.carriesCredential(url) else {
                throw SelfTestFailure.assertion("prévia de link não pode visitar \(raw)")
            }
        }

        let allowed = [
            "https://exemplo.com/artigo/como-fazer-pao",
            "https://exemplo.com/busca?q=pao&page=2",
            "https://exemplo.com",
        ]
        for raw in allowed {
            guard let url = URL(string: raw), !LinkPreviewService.carriesCredential(url) else {
                throw SelfTestFailure.assertion("prévia de link recusou um link comum: \(raw)")
            }
        }
    }

    private static func checkClipboardViewShowsEverything(store: Store, pinboardID: Int64) throws {
        let text = "usado a partir da pasta"
        let fingerprint = try Crypto.fingerprint(Data(text.utf8))
        let filed = ClipItem(
            id: nil, kind: .text, title: nil, preview: text,
            fingerprint: fingerprint,
            blobPath: nil, byteSize: text.utf8.count, charCount: text.count,
            sourceBundleID: "io.local.clipbar.self-test", sourceName: "Self Test",
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastUsedAt: Date(timeIntervalSinceNow: -3600), pinboardID: pinboardID
        )
        let filedID = try store.upsert(filed).id

        guard try store.items(pinboardID: nil).contains(where: { $0.id == filedID }) else {
            throw SelfTestFailure.assertion("a área de transferência deve listar itens de pastas")
        }

        // Re-copying content that is already filed: bumps the filed row, never
        // inserts an unfiled twin.
        var recapture = filed
        recapture.pinboardID = nil
        recapture.createdAt = Date()
        let recaptureID = try store.upsert(recapture).id
        guard recaptureID == filedID else {
            throw SelfTestFailure.assertion("recopiar item já arquivado não pode criar duplicata")
        }
        guard try store.allItems().filter({ $0.fingerprint == fingerprint }).count == 1 else {
            throw SelfTestFailure.assertion("só pode existir uma linha por conteúdo")
        }
        guard try store.items(pinboardID: pinboardID).contains(where: { $0.id == filedID }) else {
            throw SelfTestFailure.assertion("recopiar não pode tirar o item da pasta")
        }

        try store.touch(id: filedID)
        guard try store.items(pinboardID: nil).first?.id == filedID else {
            throw SelfTestFailure.assertion("usar um item deve levá-lo ao topo")
        }
    }

    /// Two rows pointing at one encrypted file: deleting the first must not
    /// report it as orphaned, deleting the last one must.
    private static func checkSharedBlobSurvivesOneDelete(store: Store, blobs: BlobStore,
                                                         pinboardID: Int64) throws {
        let payload = Data("imagem compartilhada".utf8)
        let path = try blobs.write(payload, extension: "png")

        func imageRow(_ label: String) throws -> ClipItem {
            ClipItem(
                id: nil, kind: .image, title: label, preview: label,
                fingerprint: try Crypto.fingerprint(Data(label.utf8)),
                blobPath: path, byteSize: payload.count, charCount: label.count,
                sourceBundleID: "io.local.clipbar.self-test", sourceName: "Self Test",
                createdAt: Date(), lastUsedAt: Date(), pinboardID: pinboardID
            )
        }

        let first = try store.upsert(imageRow("Imagem A")).id
        let second = try store.upsert(imageRow("Imagem B")).id

        guard try store.delete(id: first).isEmpty else {
            throw SelfTestFailure.assertion("blob ainda referenciado não pode ser apagado")
        }
        guard (try? blobs.read(path)) != nil else {
            throw SelfTestFailure.assertion("blob compartilhado sumiu cedo demais")
        }
        guard try store.delete(id: second) == [path] else {
            throw SelfTestFailure.assertion("último dono do blob deve liberá-lo")
        }
    }
}
