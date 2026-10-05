import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var overlay: OverlayController?
    private var monitor: ClipboardMonitor?
    private var store: Store?
    private var preferencesController: PreferencesController?
    private var retentionTimer: Timer?
    private var welcomeController: WelcomeController?
    private var blobs: BlobStore?
    private var openMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        do {
            let store = try Store(url: Paths.database)
            // Running on would show an empty bar and fail every capture, which
            // reads exactly like "everything I saved is gone".
            if Crypto.keyIsMissing {
                presentFatal(Crypto.Failure.keyMissing)
                return
            }
            let blobs = try BlobStore(root: Paths.blobs)
            Thumbnails.blobs = blobs
            self.blobs = blobs
            self.store = store

            let monitor = ClipboardMonitor(store: store, blobs: blobs)
            monitor.blockedBundleIDs = Set(Preferences.blockedBundleIDs)
            monitor.start()
            self.monitor = monitor

            pruneHistory()
            // Age-based retention has to keep working while the app just sits
            // there; without this, a machine left running for a week would only
            // sweep at the next launch.
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.pruneHistory()
            }

            let overlay = OverlayController(store: store, blobs: blobs, monitor: monitor)
            self.overlay = overlay
            monitor.onChange = { [weak overlay] in overlay?.reloadIfVisible() }
            registerHotKey()

            // Next run loop pass, so the menu bar icon paints first. See
            // OverlayController.warmUp for what this is buying and what it cost
            // not to have it.
            DispatchQueue.main.async { [weak overlay] in overlay?.warmUp() }

            preferencesController = PreferencesController(actions: PreferencesActions(
                reregisterHotKey: { [weak self] in self?.registerHotKey() },
                applyBlockedApps: { [weak self] in
                    self?.monitor?.blockedBundleIDs = Set(Preferences.blockedBundleIDs)
                },
                pruneHistory: { [weak self] in self?.pruneHistory() },
                looseItemCount: { [weak self] in
                    guard let store = self?.store else { return 0 }
                    return (try? store.looseItemCount()) ?? 0
                },
                clearHistory: { [weak self] in
                    guard let self, let store = self.store else { return }
                    for orphan in (try? store.clearLooseHistory()) ?? [] {
                        self.blobs?.delete(orphan)
                    }
                    self.overlay?.reloadIfVisible()
                }
            ))
            overlay.onOpenPreferences = { [weak self] in self?.preferencesController?.show() }

            welcomeController = WelcomeController(
                openPreferences: { [weak self] in self?.preferencesController?.show() }
            )
            welcomeController?.showIfFirstLaunch()
        } catch {
            Log.store.error("could not open the store — \(String(describing: error), privacy: .public)")
            presentFatal(error)
            return
        }

    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "ClipBar"
        )

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Abrir", action: #selector(openBar), keyEquivalent: "")
        open.target = self
        openMenuItem = open
        refreshOpenMenuItem()
        menu.addItem(withTitle: "Itens guardados…", action: #selector(showCounts), keyEquivalent: "")
            .target = self
        // Reachable exactly when the shortcut is not, which is the only moment
        // anyone wants it.
        menu.addItem(withTitle: "Diagnóstico do atalho…", action: #selector(showHotKeyDiagnostics),
                     keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Boas-vindas…", action: #selector(openWelcome), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
    }

    @objc private func openBar() {
        overlay?.show()
    }

    /// Applies both retention rules and removes the files the deleted rows owned.
    private func pruneHistory() {
        guard let store else { return }
        var orphans: [String] = []
        orphans += (try? store.pruneHistory(keeping: Preferences.historyLimit)) ?? []
        orphans += (try? store.pruneHistory(olderThanDays: Preferences.historyRetentionDays)) ?? []
        for path in orphans { blobs?.delete(path) }

        // Reference counting only frees a blob when the row that owns it is
        // deleted through the app. A crash, a force-quit or a failed write
        // between "file on disk" and "row in the database" leaves a file nobody
        // will ever ask about again — 19 MB of them had piled up before anything
        // went looking. Nothing else in the app ever revisits the directory, so
        // this sweep is the only thing that can notice.
        if let blobs, let referenced = try? store.referencedBlobPaths() {
            let freed = blobs.sweepOrphans(keeping: referenced)
            if freed > 0 { Log.store.notice("swept \(freed, privacy: .public) unreferenced blobs") }
        }

        overlay?.reloadIfVisible()
    }

    @objc private func openPreferences() {
        preferencesController?.show()
    }

    @objc private func openWelcome() {
        welcomeController?.show()
    }

    /// Rebuilt from preferences rather than hardcoded, so the menu can't go on
    /// advertising ⌘⌥V after the shortcut has been changed.
    private func refreshOpenMenuItem() {
        openMenuItem?.title = "Abrir  \(Preferences.hotKeyLabel)"
    }

    private func registerHotKey() {
        // Dropping the old one first: Carbon keeps every registration alive, so
        // skipping this would leave the previous combination still opening the bar.
        hotKey = nil
        hotKey = HotKey(
            keyCode: Preferences.hotKeyCode,
            modifiers: Preferences.hotKeyModifiers
        ) { [weak self] in
            self?.overlay?.toggle()
        }
        if hotKey == nil {
            Log.hotKey.error("RegisterEventHotKey refused the combination")
        }
        refreshOpenMenuItem()
    }

    @objc private func showHotKeyDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "Diagnóstico do atalho"
        alert.informativeText = Diagnostics.hotKeyReport() + "\n\n" + Diagnostics.hotKeyAdvice()
        alert.addButton(withTitle: "Fechar")
        alert.addButton(withTitle: "Abrir Preferências…")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            preferencesController?.show()
        }
    }

    @objc private func showCounts() {
        guard let store else { return }
        let items = (try? store.count(table: "items")) ?? 0
        let boards = (try? store.count(table: "pinboards")) ?? 0

        let alert = NSAlert()
        alert.messageText = "ClipBar"
        alert.informativeText = "\(items) itens · \(boards) pastas\n\n\(Paths.database.path)"
        alert.runModal()
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ClipBar não conseguiu abrir o banco"
        if case Crypto.Failure.keyMissing = error {
            alert.informativeText = """
                A chave que decifra seus itens não está no Keychain (serviço io.local.clipbar, \
                contas db-key-v2 e db-key-v1). O ClipBar não criou uma chave nova porque isso \
                deixaria todos os itens já guardados ilegíveis para sempre.

                Procure o item no app Acesso às Chaves ou restaure o Keychain de um backup \
                antes de abrir o ClipBar de novo. O banco não foi alterado.
                """
        } else {
            alert.informativeText = "\(error)"
        }
        alert.runModal()
        NSApp.terminate(nil)
    }
}
