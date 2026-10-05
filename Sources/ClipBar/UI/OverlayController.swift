import AppKit
import Combine
import SwiftUI

/// Owns the panel: where it appears, who had focus before it did, and giving
/// that focus back.
///
/// Note on activation: we *do* activate ClipBar when showing the bar. A
/// non-activating panel never receives key events while another app is active,
/// so Escape and type-to-search would be dead. Instead of avoiding activation,
/// we remember the previous app and hand focus straight back on dismiss —
/// which is also what makes paste land in the right window.
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var previousApp: NSRunningApplication?
    private var askedForAccessibility = false

    private var preview: PreviewPanel?
    /// One decrypted image, kept while it is the one on screen. Arrowing along a
    /// row of screenshots would otherwise decrypt and decode the same blob again
    /// on every repeat of the key.
    private var previewCache: (path: String, image: NSImage)?
    private var previewFollowsSelection: AnyCancellable?

    /// When the panel was last put on screen. `windowDidResignKey` needs it:
    /// activation is a handoff, and losing key status *during* the handoff is
    /// not the user dismissing the bar.
    private var shownAt = Date.distantPast

    /// How long after `show()` a lost key status still counts as the handoff
    /// bouncing rather than a dismissal.
    private static let activationSettleWindow: TimeInterval = 0.4

    /// Set by AppDelegate — the controller owns the panel, not the preferences.
    var onOpenPreferences: (() -> Void)?

    private let model: BarViewModel
    private let blobs: BlobStore
    private weak var monitor: ClipboardMonitor?

    // 24 outer padding + 28 tabs + 12 + 242 cards + 12 + 14 hints = 332, plus slack.
    private let barHeight: CGFloat = 356
    private let sideMargin: CGFloat = 16
    private let bottomMargin: CGFloat = 16

    init(store: Store, blobs: BlobStore, monitor: ClipboardMonitor?) {
        self.model = BarViewModel(store: store, blobs: blobs)
        self.blobs = blobs
        self.monitor = monitor
        super.init()

        // An open preview follows the selection wherever it moves from — arrow
        // keys, a click on a card, the list reloading underneath. Driving it
        // from the model instead of from the key handler is what makes the mouse
        // work too, for free. Delivered on the next run loop pass because
        // @Published fires *before* the new value lands.
        previewFollowsSelection = Publishers.Merge(
            model.$selection.map { _ in () },
            model.$visible.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshPreview() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    /// Pays the first-open costs now, at launch, instead of under the shortcut.
    ///
    /// Measured on the first ⌘⌥V after a launch, from the unified log: 7.7 s
    /// inside the first Keychain read for the database key, then 5.6 s building
    /// the hosting view and decoding the first thumbnails. Thirteen seconds of
    /// blocked main thread, during which every further press of the shortcut sat
    /// in the Carbon queue and then replayed as rapid toggles the instant the run
    /// loop breathed again.
    ///
    /// That is the whole of "sometimes it opens, sometimes it doesn't". The bar
    /// was opening — thirteen seconds late — and the queued presses closed it
    /// again on the way past. Nobody is waiting at launch, so the same work
    /// costs nothing there.
    ///
    /// The Keychain half still runs off the main thread. `Crypto.loadKey` has
    /// since removed the nine seconds — that was an ACL left behind by an ad-hoc
    /// signed build — but a Keychain read is a call into another process and has
    /// no business blocking the run loop that polls the clipboard. Everything
    /// after it touches AppKit, so it has to come back.
    ///
    /// What remains, measured: 38 ms in the store, 297 ms building the interface.
    func warmUp() {
        // The one-time key migration raises a Keychain authorization dialog, and
        // SecurityAgent does not bring that dialog forward for an app that isn't
        // frontmost: it spawns behind everything, invisible, and the read waits
        // on a window nobody can see. Being active while we ask is what puts it
        // in front of the person who has to answer it. Once. After that the ACL
        // matches by certificate and no dialog is raised again.
        if Crypto.needsKeyMigration {
            Log.store.notice("migrating the database key — a Keychain dialog is expected")
            NSApp.activate(ignoringOtherApps: true)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? Crypto.key()
            DispatchQueue.main.async { self.warmUpInterface() }
        }
    }

    private func warmUpInterface() {
        let start = Date()
        model.reload()
        let loaded = Date()
        let panel = self.panel ?? makePanel(frame: barFrame(on: Self.screenWithMouse()))
        panel.contentView?.layoutSubtreeIfNeeded()
        Log.overlay.notice("""
            warm-up done — store \(Int(loaded.timeIntervalSince(start) * 1000), privacy: .public) ms, \
            interface \(Int(Date().timeIntervalSince(loaded) * 1000), privacy: .public) ms
            """)
    }

    func toggle() {
        Log.overlay.notice("toggle — panel \(self.isVisible ? "visible, hiding" : "hidden, showing", privacy: .public)")
        isVisible ? hide() : show()
    }

    func show() {
        // Capture this *before* we activate, or we'd just record ourselves.
        previousApp = NSWorkspace.shared.frontmostApplication

        model.cancelEditing()
        model.search = ""
        model.selection = 0
        model.reload()

        let frame = barFrame(on: Self.screenWithMouse())
        let panel = self.panel ?? makePanel(frame: frame)
        panel.setFrame(frame, display: false)

        shownAt = Date()

        // Order the panel onto the *current* space before activating. Activation
        // switches to whichever space the app already has a window on; with the
        // panel still hidden, an accessory app has none, so macOS leaves the
        // active full-screen space to reach ClipBar's own — measured as the bar
        // simply never showing up while a full-screen app was in front. Ordering
        // first (orderFrontRegardless works from an inactive app) puts a window
        // on the space the user is looking at, and activation stays put.
        //
        // This call alone is what guarantees the bar is *seen*: it works from an
        // inactive app, and `.statusBar` level puts the panel over the Dock, the
        // menu bar and every ordinary window. Whether the bar also *responds* to
        // the keyboard is a separate question, answered by takeFocus below.
        panel.orderFrontRegardless()
        Log.overlay.notice("""
            show — previous app \(self.previousApp?.bundleIdentifier ?? "none", privacy: .public), \
            app active \(NSApp.isActive, privacy: .public), \
            board \(self.model.activePinboardID.map(String.init) ?? "clipboard", privacy: .public), \
            filter \(self.model.kindFilter.count, privacy: .public), \
            \(self.model.visible.count, privacy: .public) cards, \
            top id \(self.model.visible.first?.id ?? -1, privacy: .public)
            """)
        takeFocus()

        installKeyMonitor()
    }

    /// Ask for activation, then verify we actually got it — and ask again if not.
    ///
    /// `activate(ignoringOtherApps:)` is the deprecated forced variant, kept on
    /// purpose: its macOS 14 replacement is cooperative, and AppKit states
    /// outright that the framework does not guarantee activation and that the
    /// frontmost app is expected to call `yieldActivationToApplication:` first.
    /// A global hotkey gives that app no reason to yield. But the forced variant
    /// is not a guarantee either — since Sonoma it can be refused just as
    /// silently, and a panel that never becomes key gets no key events, so
    /// Escape and type-to-search die with no visible cause.
    ///
    /// So the request is treated as a request. Activation is asynchronous, so
    /// the panel is never key on the way out of this call; the retry fires only
    /// while it is still not key a beat later, and stops the moment it is.
    private func takeFocus(attempt: Int = 0) {
        guard let panel, panel.isVisible else { return }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)

        guard attempt < 4 else {
            Log.overlay.error("panel never took key focus — bar is visible but deaf")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let panel = self.panel,
                  panel.isVisible, !panel.isKeyWindow
            else { return }
            self.takeFocus(attempt: attempt + 1)
        }
    }

    func hide(restoringFocus: Bool = true) {
        removeKeyMonitor()
        closePreview()
        panel?.orderOut(nil)
        if restoringFocus { previousApp?.activate() }
    }

    // MARK: - Paste

    private func pasteSelected() {
        guard let item = model.selectedItem else { return }

        Paster.place(item, blobs: blobs, monitor: monitor)
        model.recordUse(item)
        Feedback.pasted()
        let canAutoPaste = Paster.canAutoPaste

        removeKeyMonitor()
        closePreview()
        panel?.orderOut(nil)
        previousApp?.activate()

        guard Preferences.autoPasteEnabled else { return }

        if !canAutoPaste {
            // The item is on the clipboard either way — Cmd+V works right now.
            // Explain once per launch rather than silently doing nothing.
            if !askedForAccessibility {
                askedForAccessibility = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.explainAccessibility() }
            }
            return
        }

        // The target app needs a beat to actually become frontmost; firing
        // Cmd+V into a window that isn't focused yet just loses the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.sendCommandV()
        }
    }

    /// Like pasting, minus the keystroke: the item lands on the clipboard and the
    /// bar gets out of the way, leaving the user to place it themselves.
    private func copySelected() {
        guard let item = model.selectedItem else { return }
        Paster.place(item, blobs: blobs, monitor: monitor)
        model.recordUse(item)
        Feedback.captured()
        hide()
    }

    private func explainAccessibility() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Para colar sozinho, o ClipBar precisa de Acessibilidade"
        alert.informativeText = [
            "O item já está na sua área de transferência — pode apertar ⌘V agora.",
            "Para o ClipBar colar sozinho ao apertar ⏎, autorize-o em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade.",
            "Enquanto estivermos desenvolvendo, o macOS revoga essa permissão a cada recompilação, porque ela é vinculada à assinatura do app. Se o colar automático parar de funcionar, é isso — basta reautorizar.",
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Paster.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Panel

    private func makePanel(frame: NSRect) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame)
        let view = BarView(
            model: model,
            onActivate: { [weak self] index in
                guard let self else { return }
                self.model.select(index: index)
                self.pasteSelected()
            },
            onCopy: { [weak self] index in
                guard let self else { return }
                self.model.select(index: index)
                self.copySelected()
            },
            onPreferences: { [weak self] in
                // Not restoring focus: the preferences window is about to take it.
                self?.hide(restoringFocus: false)
                self?.onOpenPreferences?()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Clicking away from the bar dismisses it, the way Spotlight does.
    ///
    /// Except in the first fraction of a second, where losing key status means
    /// the activation handoff bounced — the app we took focus from asked for it
    /// back before the panel settled. Dismissing on that bounce is precisely the
    /// "bar flickers once and vanishes" report; the fix is to ask again rather
    /// than to give up, and to treat only a later resign as the user leaving.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }

        guard Date().timeIntervalSince(shownAt) > Self.activationSettleWindow else {
            Log.overlay.notice("key status bounced during the activation handoff — asking again")
            takeFocus()
            return
        }

        hide(restoringFocus: false)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors keep firing inside runModal: without this, ⏎ on a
            // confirmation alert raised from the bar would also paste.
            guard NSApp.modalWindow == nil else { return event }
            return self?.handle(event) == true ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    /// Only for a notched mouse wheel.
    ///
    /// Trackpads are left alone deliberately: the card row is a real horizontal
    /// ScrollView and already scrolls smoothly under a two-finger swipe. This
    /// monitor does not consume the event, so stepping the selection here as well
    /// meant both things happened at once and fought each other — which is what
    /// made trackpad scrolling feel stuck rather than fluid.
    ///
    /// A wheel is the case where nothing happens on its own: it reports vertical
    /// delta only, and a horizontal ScrollView ignores it.
    private func handleScroll(_ event: NSEvent) {
        guard model.mode == .browsing else { return }
        guard !event.hasPreciseScrollingDeltas else { return }
        guard event.momentumPhase == [] else { return }

        scrollAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = 4
        while abs(scrollAccumulator) >= threshold {
            model.move(by: scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator -= scrollAccumulator > 0 ? threshold : -threshold
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        scrollAccumulator = 0
    }

    /// Returns true when the key was consumed.
    ///
    /// The bar has modal editors (rename, move, new pinboard). Each owns the
    /// keyboard completely while it is up, so a stray arrow key can't quietly
    /// change what you're about to act on.
    private func handle(_ event: NSEvent) -> Bool {
        switch model.mode {
        case .browsing:         return handleBrowsing(event)
        case .renamingItem:     return handleTextEntry(event, commit: model.commitRename)
        case .creatingPinboard: return handleTextEntry(event, commit: model.commitCreatePinboard)
        case .renamingPinboard: return handleTextEntry(event, commit: model.commitRenamePinboard)
        case .movingItem:       return handleMove(event)
        }
    }

    private func handleBrowsing(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c": copySelected(); return true
            case "r": model.beginRename(); return true
            case "p": model.beginMove(); return true
            case "n": model.beginCreatePinboard(); return true
            case ",":
                // The gear button's tooltip has been promising this shortcut
                // since the button existed; nothing was listening for it.
                hide(restoringFocus: false)
                onOpenPreferences?()
                return true
            default: break
            }
            // Cmd+1..9 picks a card outright.
            if let number = Int(key), (1...9).contains(number) {
                guard model.visible.indices.contains(number - 1) else { return true }
                model.select(index: number - 1)
                pasteSelected()
                return true
            }
            return false
        }

        switch event.keyCode {
        case 53:                                                         // Escape
            // The preview is a layer on top of the bar, so Escape peels it off
            // first. Closing both at once loses the place you were looking at.
            if isPreviewing { closePreview() } else { hide() }
            return true
        case 49:                                                         // Space
            // Only when the search box is empty. Space is a character first —
            // stealing it outright would make "pix renan" unsearchable, and a
            // two-word search is exactly what the naming feature is for.
            guard model.search.isEmpty else { break }
            togglePreview()
            return true
        case 123: model.move(by: -1); return true                       // Left
        case 124: model.move(by: 1); return true                        // Right
        case 126: model.switchPinboard(by: -1); return true             // Up
        case 125: model.switchPinboard(by: 1); return true              // Down
        case 48:  model.switchPinboard(by: shift ? -1 : 1); return true // Tab
        case 36, 76: pasteSelected(); return true                       // Return
        case 51:                                                         // Delete
            if model.search.isEmpty { model.deleteSelected() } else { model.search.removeLast() }
            return true
        default:
            break
        }

        guard let characters = printable(event) else { return false }
        closePreview()
        model.search += characters
        return true
    }

    // MARK: - Image preview

    private var isPreviewing: Bool { preview?.isVisible ?? false }

    private func togglePreview() {
        isPreviewing ? closePreview() : openPreview()
    }

    private func openPreview() {
        guard let image = fullImage(for: model.selectedItem) else { return }

        let panel = preview ?? PreviewPanel()
        preview = panel
        panel.show(image, in: previewArea())
    }

    /// Keeps an open preview pointed at whatever is selected now, the way
    /// QuickLook follows the selection in Finder. Closes itself when the
    /// selection moves to something there is nothing to preview.
    private func refreshPreview() {
        guard isPreviewing else { return }
        guard let image = fullImage(for: model.selectedItem) else {
            closePreview()
            return
        }
        preview?.show(image, in: previewArea())
    }

    private func closePreview() {
        preview?.dismiss()
        previewCache = nil
    }

    /// Full resolution, straight from the blob — `Thumbnails` caches a downscaled
    /// copy sized for a card, which is the one thing a preview must not show.
    private func fullImage(for item: ClipItem?) -> NSImage? {
        guard let item, item.kind == .image, let path = item.blobPath else { return nil }
        if let previewCache, previewCache.path == path { return previewCache.image }

        guard let data = try? blobs.read(path), let image = NSImage(data: data) else { return nil }
        previewCache = (path, image)
        return image
    }

    /// The screen above the bar, with a gap so the two don't touch.
    private func previewArea() -> NSRect {
        let screen = Self.screenWithMouse()
        let visible = screen.visibleFrame
        let bar = barFrame(on: screen)
        let bottom = bar.maxY + 12
        return NSRect(x: visible.minX + sideMargin,
                      y: bottom,
                      width: visible.width - sideMargin * 2,
                      height: max(visible.maxY - bottom - 12, 1))
    }

    private func handleTextEntry(_ event: NSEvent, commit: () -> Void) -> Bool {
        switch event.keyCode {
        case 36, 76: commit(); return true                 // Return
        case 53:     model.cancelEditing(); return true    // Escape
        case 51:                                            // Delete
            if !model.draft.isEmpty { model.draft.removeLast() }
            return true
        default:
            break
        }

        guard let characters = printable(event) else { return true }
        model.draft += characters
        return true
    }

    private func handleMove(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 53:     model.cancelEditing(); return true                     // Escape
        case 123:    model.moveHighlight(by: -1); return true               // Left
        case 124:    model.moveHighlight(by: 1); return true                // Right
        case 48:     model.moveHighlight(by: shift ? -1 : 1); return true   // Tab
        case 36, 76: model.completeMove(to: model.moveSelection); return true // Return
        default:     break
        }

        // Digits stay as a shortcut for the first nine, but they are no longer
        // the only way in: there are more pinboards than digits.
        if let key = event.charactersIgnoringModifiers, let number = Int(key),
           (1...9).contains(number) {
            model.completeMove(to: number - 1)
            return true
        }
        return true  // the picker owns the keyboard until it resolves
    }

    private func printable(_ event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return characters
    }

    // MARK: - Geometry

    private func barFrame(on screen: NSScreen) -> NSRect {
        // visibleFrame, not frame: keeps us clear of the Dock and menu bar.
        let area = screen.visibleFrame
        return NSRect(
            x: area.minX + sideMargin,
            y: area.minY + bottomMargin,
            width: area.width - sideMargin * 2,
            height: barHeight
        )
    }

    private static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
