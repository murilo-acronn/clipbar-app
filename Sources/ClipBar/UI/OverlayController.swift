import AppKit
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
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    func toggle() { isVisible ? hide() : show() }

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

        // Deliberately the deprecated forced variant. Its macOS 14 replacement,
        // NSApp.activate(), is cooperative: AppKit states outright that the
        // framework does not guarantee activation at all, and that the frontmost
        // app is expected to call yieldActivationToApplication: first. A global
        // hotkey gives that app no reason to yield, so while the user is typing
        // somewhere else the request is silently refused, the panel never holds
        // key status, and windowDidResignKey below dismisses it — measured as the
        // bar flickering once and vanishing. Activation from the Finder desktop
        // worked only because nothing was contending for it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)

        installKeyMonitor()
    }

    func hide(restoringFocus: Bool = true) {
        removeKeyMonitor()
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
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        hide(restoringFocus: false)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
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
        case 53:  hide(); return true                                   // Escape
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
        model.search += characters
        return true
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
