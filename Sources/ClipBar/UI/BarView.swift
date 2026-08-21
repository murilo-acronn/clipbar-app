import AppKit
import SwiftUI

struct BarView: View {
    @ObservedObject var model: BarViewModel
    /// Double-click acts on a card the way Return does — the gesture the user
    /// carried over from Paste.
    let onActivate: (Int) -> Void
    /// Puts the item on the clipboard without pasting it anywhere.
    let onCopy: (Int) -> Void
    let onPreferences: () -> Void

    @State private var updateResult: Updater.Result?
    @State private var checkingUpdate = false

    /// Hand-rolled double-click detection. Combining a count-2 and a count-1
    /// TapGesture on the same view forces SwiftUI to hold the single tap for the
    /// whole double-click window before committing to it — selection then feels
    /// laggy, because it's waiting to see if a second click is coming. A single
    /// count-1 gesture never waits; it fires immediately, and we detect the
    /// second click ourselves against the system's own double-click interval.
    @State private var lastTapIndex: Int?
    @State private var lastTapTime: Date = .distantPast

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            VStack(spacing: 12) {
                topBar
                cards
                hints
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        switch model.mode {
        case .browsing:
            tabs
        case .renamingItem:
            editor(icon: "pencil", label: "Nome:")
        case .creatingPinboard:
            editor(icon: "folder.badge.plus", label: "Nova pasta:")
        case .renamingPinboard:
            editor(icon: "folder", label: "Nome da pasta:")
        case .movingItem:
            movePicker
        }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            searchField

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tab(title: "Área de transferência", color: nil, id: nil)
                    ForEach(model.pinboards, id: \.id) { board in
                        tab(title: board.name, color: color(board.color), id: board.id)
                    }
                    Button { model.beginCreatePinboard() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nova pasta (⌘N)")
                }
            }

            Button { onPreferences() } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .opacity(0.75)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preferências (⌘,)")
        }
        .frame(height: 28)
    }

    private func tab(title: String, color: Color?, id: Int64?) -> some View {
        let isActive = model.activePinboardID == id && !model.isSearchingGlobally
        return Button {
            model.open(pinboardID: id)
        } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(title).font(.system(size: 13, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(isActive ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let id {
                Button("Renomear pasta…") { model.beginRenamePinboard(id: id) }
                Button("Excluir pasta…", role: .destructive) {
                    guard let board = model.pinboards.first(where: { $0.id == id }) else { return }
                    confirmDelete(board)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).opacity(0.6)

            // Not an NSTextField: focus inside a borderless panel is fragile, so
            // OverlayController routes every keystroke straight here. The caret
            // is drawn whenever the bar is browsing because that is the truth —
            // this field is never *not* taking input, so there is nothing to
            // click into. Clicking used to clear the search, which is the
            // opposite of what clicking a search field should do.
            HStack(spacing: 2) {
                Text(model.search)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if model.mode == .browsing {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: 15)
                }
                if model.search.isEmpty {
                    Text("buscar por nome ou conteúdo…")
                        .font(.system(size: 13))
                        .opacity(0.45)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            if !model.search.isEmpty {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).opacity(0.6)
                }
                .buttonStyle(.plain)
                .help("Limpar a busca")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .frame(width: 240, alignment: .leading)
        .background(Color.black.opacity(0.22), in: Capsule())
        .contentShape(Capsule())
    }

    private func editor(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).opacity(0.7)
            Text(label).font(.system(size: 13)).opacity(0.6)
            HStack(spacing: 1) {
                Text(model.draft).font(.system(size: 14, weight: .medium))
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 17)
            }
            Spacer()
            Text("⏎ salvar · esc cancelar").font(.system(size: 12)).opacity(0.45)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
    }

    private var movePicker: some View {
        HStack(spacing: 6) {
            Text("Mover para:").font(.system(size: 13)).opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(model.moveTargets.enumerated()), id: \.offset) { index, target in
                            let isHighlighted = index == model.moveSelection
                            HStack(spacing: 4) {
                                // Only the first nine have a digit to show; the
                                // rest are reached with the arrows.
                                if index < 9 {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.white.opacity(0.16), in: Capsule())
                                }
                                Circle().fill(color(target.color)).frame(width: 8, height: 8)
                                Text(target.name).font(.system(size: 13))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(isHighlighted ? 0.28 : 0.08), in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    Color.white.opacity(isHighlighted ? 0.55 : 0), lineWidth: 1)
                            )
                            .id(index)
                            .onTapGesture { model.completeMove(to: index) }
                        }
                    }
                }
                .onChange(of: model.moveSelection) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            Text("← → escolhe · ⏎ move · esc").font(.system(size: 12)).opacity(0.45)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        if model.visible.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: model.search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 26)).opacity(0.3)
                Text(emptyMessage).font(.system(size: 13)).opacity(0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, item in
                            CardView(item: item,
                                     isSelected: model.isSelected(index),
                                     index: index,
                                     accent: accent(for: item),
                                     pinboardName: badge(for: item))
                                .id(index)
                                // SwiftUI's tap gesture carries no modifier flags,
                                // so read them from the event that is being handled.
                                .onTapGesture {
                                    let flags = NSEvent.modifierFlags
                                    if flags.contains(.shift) {
                                        model.extendSelection(to: index)
                                    } else if flags.contains(.command) {
                                        model.toggleSelection(at: index)
                                    } else {
                                        model.select(index: index)
                                        let now = Date()
                                        if lastTapIndex == index,
                                           now.timeIntervalSince(lastTapTime) < NSEvent.doubleClickInterval {
                                            onActivate(index)
                                            lastTapIndex = nil
                                        } else {
                                            lastTapIndex = index
                                            lastTapTime = now
                                        }
                                    }
                                }
                                .contextMenu { cardMenu(index: index) }
                                .draggable(String(item.id ?? -1))
                                .dropDestination(for: String.self) { values, location in
                                    guard let raw = values.first, let draggedID = Int64(raw) else { return false }
                                    let insertion = index + (location.x >= 118 ? 1 : 0)
                                    return model.reorder(itemID: draggedID, insertionIndex: insertion)
                                }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                }
                .onChange(of: model.selection) { _, new in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }


    /// Shortcuts are spelled out in the titles rather than attached with
    /// .keyboardShortcut: the panel already routes every keystroke itself, and a
    /// second registration would compete with it.
    @ViewBuilder
    private func cardMenu(index: Int) -> some View {
        Button("Colar   ⏎") { onActivate(index) }
        Button("Copiar   ⌘C") { onCopy(index) }

        Divider()

        Button("Renomear   ⌘R") {
            model.select(index: index)
            model.beginRename()
        }

        Menu("Mover para") {
            ForEach(Array(model.moveTargets.enumerated()), id: \.offset) { position, target in
                Button(target.name) {
                    model.select(index: index)
                    model.completeMove(to: position)
                }
            }
        }

        Divider()

        Button(model.multiSelection.count > 1 && model.multiSelection.contains(index)
               ? "Excluir \(model.multiSelection.count) itens   ⌫"
               : "Excluir   ⌫",
               role: .destructive) {
            // Right-clicking outside the block acts on that one card instead.
            if !(model.multiSelection.count > 1 && model.multiSelection.contains(index)) {
                model.select(index: index)
            }
            model.deleteSelected()
        }
    }

    private var hints: some View {
        HStack(spacing: 12) {
            hint("⏎", "colar")
            hint("⌘R", "renomear")
            hint("⌘P", "mover")
            hint("⌘N", "nova pasta")
            hint("⌫", model.multiSelection.count > 1
                        ? "apagar \(model.multiSelection.count)"
                        : "apagar")
            Spacer()
            if model.isSearchingGlobally {
                Text("\(model.visible.count) resultados em todas as pastas")
                    .font(.system(size: 11)).opacity(0.5)
            }
            updateHint
        }
        .frame(height: 14)
        .opacity(model.mode == .browsing ? 1 : 0)
    }

    @ViewBuilder
    private var updateHint: some View {
        // A single action, branching on state — a Button's own tap handling and
        // a layered onTapGesture on the same view double-fire instead of just
        // being redundant, which is worse than the delay bug this pattern caused
        // in CardView. One gesture, one path.
        Button {
            if case .available = updateResult {
                confirmAndApplyUpdate()
                return
            }
            checkingUpdate = true
            Task {
                let result = await Updater.check()
                await MainActor.run {
                    checkingUpdate = false
                    updateResult = result
                }
            }
        } label: {
            HStack(spacing: 4) {
                if checkingUpdate {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: updateIcon).font(.system(size: 10))
                }
                Text(updateLabel).font(.system(size: 11))
            }
            .opacity(0.55)
        }
        .buttonStyle(.plain)
        .disabled(checkingUpdate)
        .help(updateHelp)
    }

    private var updateIcon: String {
        switch updateResult {
        case .available: return "arrow.down.circle.fill"
        case .upToDate:  return "checkmark.circle"
        case .failed:    return "exclamationmark.circle"
        case nil:        return "arrow.triangle.2.circlepath"
        }
    }

    private var updateLabel: String {
        switch updateResult {
        case let .available(version, _): return "atualizar para \(version)"
        case .upToDate:                  return "atualizado"
        case .failed:                    return "verificar atualizações"
        case nil:                        return "verificar atualizações"
        }
    }

    private var updateHelp: String {
        switch updateResult {
        case .available:
            return Updater.canApplyUpdate()
                ? "Clique para recompilar e reiniciar o ClipBar com a versão nova"
                : "Clone original não encontrado — clique para abrir o release no GitHub"
        case .upToDate:            return "Você já está na versão mais recente"
        case let .failed(reason):  return reason
        case nil:                  return "Consulta o GitHub — nenhum dado seu é enviado"
        }
    }

    /// Applying is a one-way trip: this app quits partway through, so the user
    /// gets one clear heads-up before it happens rather than a surprise.
    private func confirmAndApplyUpdate() {
        guard case let .available(version, url) = updateResult else { return }

        guard Updater.canApplyUpdate() else {
            NSWorkspace.shared.open(url)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Atualizar para a versão \(version)?"
        alert.informativeText = "O ClipBar vai buscar o código novo, recompilar e reabrir sozinho — leva alguns segundos. Nada disso acontece sem essa confirmação."
        alert.addButton(withTitle: "Atualizar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        checkingUpdate = true
        Task {
            let result = await Updater.applyUpdate()
            // Reached only on failure — success replaces this very process.
            await MainActor.run {
                checkingUpdate = false
                if case let .failed(reason) = result {
                    updateResult = .failed(reason)
                }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded)).opacity(0.7)
            Text(label).font(.system(size: 11)).opacity(0.4)
        }
    }

    private func confirmDelete(_ board: Pinboard) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Excluir a pasta “\(board.name)”?"
        alert.informativeText = "Os itens dela voltam para a Área de transferência. Conteúdos duplicados são unidos; nada é apagado sem já existir outra cópia."
        alert.addButton(withTitle: "Excluir pasta")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn, let id = board.id else { return }
        model.deletePinboard(id: id)
    }

    // MARK: - Helpers

    private func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? .systemBlue)
    }

    /// Pinboard colour inside a pinboard (and for search hits, the colour of
    /// whichever board they came from); content-type colour in loose history.
    private func accent(for item: ClipItem) -> Color {
        if let board = model.pinboard(for: item) { return color(board.color) }
        if !model.isSearchingGlobally, let board = model.activePinboard { return color(board.color) }
        return item.kind.accent
    }

    /// While searching across everything, say where each hit actually lives.
    private func badge(for item: ClipItem) -> String? {
        guard model.isSearchingGlobally else { return nil }
        return model.pinboard(for: item)?.name
    }

    private var emptyMessage: String {
        if !model.search.isEmpty { return "Nada encontrado para “\(model.search)”" }
        if model.activePinboardID != nil { return "Esta pasta está vazia" }
        return "Nada copiado ainda"
    }
}

/// NSVisualEffectView is still the only way to get real window vibrancy.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
