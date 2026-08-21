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
            NSLog("ClipBar: could not open the store — \(error)")
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
            NSLog("ClipBar: could not register the global hotkey (already taken?)")
        }
        refreshOpenMenuItem()
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
        alert.informativeText = "\(error)"
        alert.runModal()
        NSApp.terminate(nil)
    }
}
