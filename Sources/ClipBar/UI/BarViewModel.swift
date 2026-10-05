import AppKit
import Combine

/// State behind the bar: which pinboard is open, what's showing, what's
/// selected, and which transient editor (if any) currently owns the keyboard.
final class BarViewModel: ObservableObject {
    enum Mode: Equatable {
        case browsing
        /// Naming the selected item, so search can find it by name later.
        case renamingItem
        /// Picking a destination pinboard for the selected item.
        case movingItem
        /// Typing the name of a new pinboard.
        case creatingPinboard
        /// Editing the name of an existing pinboard from its tab menu.
        case renamingPinboard
    }

    @Published private(set) var pinboards: [Pinboard] = []
    @Published private(set) var visible: [ClipItem] = []
    @Published var selection = 0
    /// Extra cards picked with shift-click. `selection` stays the anchor, so a
    /// plain click or an arrow key still behaves exactly as before.
    @Published var multiSelection: Set<Int> = []
    @Published var activePinboardID: Int64?
    @Published var mode: Mode = .browsing
    @Published var draft = ""
    /// Highlighted destination while moving. Digits 1-9 are a shortcut, but the
    /// pinboard list outgrew them long ago — arrows have to reach the rest.
    @Published var moveSelection = 0

    @Published var search = "" {
        didSet { guard search != oldValue else { return }; refilter() }
    }

    /// Empty means "every type". Lives next to the search because it narrows the
    /// same result set — it is a way of searching, not a separate mode.
    @Published var kindFilter: Set<ClipKind> = [] {
        didSet { guard kindFilter != oldValue else { return }; refilter() }
    }

    /// Bumped every time the list is rebuilt.
    ///
    /// The card row is a ScrollView living inside a panel that is reused from one
    /// opening to the next, so it keeps the scroll offset it had last time. Open
    /// the bar, scroll to the right, close it, copy something, open it again —
    /// the new item is at the far left, off screen, and the bar looks exactly
    /// like it lost the copy. The view watches this to put the viewport back on
    /// the selection whenever the list underneath it changes.
    @Published private(set) var revision = 0

    private var loaded: [ClipItem] = []

    /// Every item, each paired with the text a search matches against, folded
    /// once here instead of once per keystroke. Search runs over the whole
    /// history on every character typed; folding hundreds of previews each time
    /// was the only part of it with a cost worth naming.
    private var everything: [(item: ClipItem, haystack: String)] = []
    private let store: Store
    private let blobs: BlobStore?
    private var editingPinboardID: Int64?

    /// Fresh pinboards cycle through these, matching the palette Paste uses.
    /// Also offered when recolouring a pinboard by hand, so a folder you rename
    /// or recolour still looks like it belongs to the same set.
    static let paletteNames = [
        "Azul", "Verde", "Amarelo", "Vermelho",
        "Roxo", "Laranja", "Cinza", "Ciano",
    ]

    static let palette = [
        "#62A9F5", "#52CC64", "#FAB700", "#F0554D",
        "#B663E0", "#FA9214", "#8F8F93", "#4DD0E1",
    ]

    init(store: Store, blobs: BlobStore? = nil) {
        self.store = store
        self.blobs = blobs
    }

    var selectedItem: ClipItem? {
        visible.indices.contains(selection) ? visible[selection] : nil
    }

    var activePinboard: Pinboard? {
        pinboards.first { $0.id == activePinboardID }
    }

    // MARK: - Loading

    func reload() {
        revision &+= 1
        pinboards = (try? store.pinboards()) ?? []
        everything = ((try? store.allItems()) ?? []).map { ($0, Self.haystack(for: $0)) }
        // The clipboard view is `everything` in the same order; decrypting the
        // whole store a second time to get it would double the cost of a reload.
        loaded = activePinboardID == nil
            ? everything.map(\.item)
            : (try? store.items(pinboardID: activePinboardID)) ?? []
        refilter()
    }

    /// Everything a search is allowed to match: the name the user gave the item,
    /// its contents, where it came from, and a link's own title and domain.
    private static func haystack(for item: ClipItem) -> String {
        [item.title ?? "", item.preview, item.sourceName ?? "",
         item.linkTitle ?? "", item.linkDomain ?? ""]
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// True while a search is showing results from outside the open pinboard.
    var isSearchingGlobally: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func pinboard(for item: ClipItem) -> Pinboard? {
        guard let id = item.pinboardID else { return nil }
        return pinboards.first { $0.id == id }
    }

    /// In-memory rather than SQL: `preview` and `title` are stored sealed, so
    /// the only place this text exists in the clear is right here, already
    /// decrypted. Matching the title is what makes "contrato modelo" work.
    private func refilter() {
        // Indices describe the old `visible` array. Keeping them while a search
        // replaces that array could make a later delete act on different items.
        multiSelection = []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty || !kindFilter.isEmpty else {
            visible = loaded
            selection = min(selection, max(visible.count - 1, 0))
            return
        }

        // A type filter with no query narrows whatever list is already on screen,
        // rather than jumping to a global search you didn't ask for.
        guard !query.isEmpty else {
            visible = loaded.filter { kindFilter.contains($0.kind) }
            selection = min(selection, max(visible.count - 1, 0))
            return
        }

        // Searching spans every pinboard, not just the open one — filing
        // filing something away shouldn't hide it when you search for it.
        // Match on each whitespace-separated term so "contrato modelo" finds
        // an item titled "Contrato — modelo 2026".
        let terms = query.split(separator: " ").map {
            String($0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }
        visible = everything.filter { entry in
            guard kindFilter.isEmpty || kindFilter.contains(entry.item.kind) else { return false }
            return terms.allSatisfy { entry.haystack.contains($0) }
        }.map(\.item)
        selection = min(selection, max(visible.count - 1, 0))
    }

    // MARK: - Filtro por tipo

    func toggleKindFilter(_ kind: ClipKind) {
        if kindFilter.contains(kind) { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
    }

    func clearKindFilter() { kindFilter = [] }

    func setPinboardColor(_ hex: String, for id: Int64) {
        try? store.setPinboardColor(id: id, color: hex)
        reload()
    }

    // MARK: - Navigation

    func move(by delta: Int) {
        multiSelection = []
        guard !visible.isEmpty else { return }
        selection = min(max(selection + delta, 0), visible.count - 1)
    }

    func select(index: Int) {
        guard visible.indices.contains(index) else { return }
        selection = index
        multiSelection = []
    }

    /// Everything between the anchor and this card, the way Finder does it.
    func extendSelection(to index: Int) {
        guard visible.indices.contains(index) else { return }
        let range = index < selection ? index...selection : selection...index
        multiSelection = Set(range)
    }

    func toggleSelection(at index: Int) {
        guard visible.indices.contains(index) else { return }
        if multiSelection.isEmpty { multiSelection = [selection] }
        if multiSelection.contains(index), multiSelection.count > 1 {
            multiSelection.remove(index)
        } else {
            multiSelection.insert(index)
        }
        selection = index
    }

    func isSelected(_ index: Int) -> Bool {
        multiSelection.isEmpty ? index == selection : multiSelection.contains(index)
    }

    /// What an action applies to: the multi-selection if there is one, otherwise
    /// just the anchor.
    var actionableIndices: [Int] {
        multiSelection.isEmpty ? [selection] : multiSelection.sorted()
    }

    func switchPinboard(by delta: Int) {
        // nil (loose history) sits at index 0, pinboards follow.
        let ids: [Int64?] = [nil] + pinboards.compactMap { $0.id }
        let current = ids.firstIndex { $0 == activePinboardID } ?? 0
        open(pinboardID: ids[(current + delta + ids.count) % ids.count])
    }

    func open(pinboardID: Int64?) {
        activePinboardID = pinboardID
        selection = 0
        search = ""
        reload()
    }

    func clearSearch() { search = "" }

    // MARK: - Items

    func deleteSelected() {
        let targets = actionableIndices.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        let ids = targets.compactMap(\.id)
        guard !ids.isEmpty else { return }

        // The clipboard view and global search list filed rows themselves, not
        // copies, so ⌫ there deletes the item out of its folder. Inside the
        // folder that is obviously the intent; anywhere else it has to be asked.
        let filedElsewhere = targets.filter { $0.pinboardID != nil && $0.pinboardID != activePinboardID }
        if !filedElsewhere.isEmpty, !confirmDeletingFiled(filedElsewhere) { return }

        for id in ids {
            // Drop the encrypted file too, or blobs/ grows forever with images
            // nothing points at any more. `try?` flattens the double optional:
            // nil means either no blob or a failed delete, and neither leaves a
            // file worth chasing.
            if let orphans = try? store.delete(id: id) {
                for orphan in orphans { blobs?.delete(orphan) }
            }
        }

        // Land on where the block used to start, not past the end of the list.
        let landing = actionableIndices.first ?? 0
        multiSelection = []
        reload()
        selection = min(landing, max(visible.count - 1, 0))
    }

    private func confirmDeletingFiled(_ items: [ClipItem]) -> Bool {
        let names = Set(items.compactMap { pinboard(for: $0)?.name }).sorted()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "Excluir um item guardado em pasta?"
            : "Excluir \(items.count) itens guardados em pastas?"
        alert.informativeText = "Está em: \(names.joined(separator: ", ")). Ele sai da pasta também, e não há como desfazer."
        alert.addButton(withTitle: "Excluir")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func beginRename() {
        guard let item = selectedItem else { return }
        // Start from your name if you gave one; start empty otherwise, rather than
        // making you erase the first line of the copied text first.
        draft = item.titleIsCustom ? (item.title ?? "") : ""
        mode = .renamingItem
    }

    func commitRename() {
        defer { cancelEditing() }
        guard let id = selectedItem?.id else { return }
        try? store.setTitle(id: id, title: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        reload()
    }

    // MARK: - Pinboards

    func beginMove() {
        guard selectedItem != nil, !pinboards.isEmpty else { return }
        moveSelection = 0
        mode = .movingItem
    }

    /// Clamps rather than wraps: at either end you want to notice you're there,
    /// not silently land on the opposite side of a 13-item list.
    func moveHighlight(by delta: Int) {
        guard !moveTargets.isEmpty else { return }
        moveSelection = min(max(moveSelection + delta, 0), moveTargets.count - 1)
    }

    /// Destinations offered while moving: loose history first, then pinboards.
    var moveTargets: [(id: Int64?, name: String, color: String)] {
        [(nil, "Área de transferência", "#8F8F93")]
            + pinboards.map { ($0.id, $0.name, $0.color) }
    }

    func completeMove(to index: Int) {
        defer { cancelEditing() }
        guard let id = selectedItem?.id, moveTargets.indices.contains(index) else { return }
        if let orphans = try? store.move(id: id, toPinboard: moveTargets[index].id) {
            for orphan in orphans { blobs?.delete(orphan) }
        }
        reload()
    }

    /// Using an item floats it to the top of the clipboard view — and that's all
    /// it does. No copy is made, because the clipboard view already lists every
    /// item including the filed ones; the item stays in its pinboard, keeps its
    /// colour, and simply becomes the most recent thing you touched.
    func recordUse(_ item: ClipItem) {
        guard let id = item.id else { return }
        try? store.touch(id: id)
    }

    func beginCreatePinboard() {
        draft = ""
        mode = .creatingPinboard
    }

    func commitCreatePinboard() {
        defer { cancelEditing() }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let color = Self.palette[pinboards.count % Self.palette.count]
        guard let id = try? store.createPinboard(name: name, color: color, sortIndex: pinboards.count) else {
            return
        }
        open(pinboardID: id)
    }

    func beginRenamePinboard(id: Int64) {
        guard let board = pinboards.first(where: { $0.id == id }) else { return }
        editingPinboardID = id
        draft = board.name
        mode = .renamingPinboard
    }

    func commitRenamePinboard() {
        defer { cancelEditing() }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let id = editingPinboardID else { return }
        try? store.renamePinboard(id: id, name: name)
        reload()
    }

    func deletePinboard(id: Int64) {
        guard let orphans = try? store.deletePinboard(id: id) else { return }
        for orphan in orphans { blobs?.delete(orphan) }
        if activePinboardID == id { activePinboardID = nil }
        reload()
    }

    /// Moves a dragged card to the insertion point reported by its target card.
    @discardableResult
    func reorder(itemID: Int64, insertionIndex: Int) -> Bool {
        guard let pinboardID = activePinboardID, !isSearchingGlobally,
              let source = visible.firstIndex(where: { $0.id == itemID })
        else { return false }

        var reordered = visible
        let item = reordered.remove(at: source)
        var destination = min(max(insertionIndex, 0), reordered.count)
        if source < insertionIndex { destination = max(0, destination - 1) }
        reordered.insert(item, at: destination)
        let ids = reordered.compactMap(\.id)
        guard ids.count == reordered.count,
              (try? store.setItemOrder(ids, pinboardID: pinboardID)) != nil
        else { return false }

        reload()
        selection = min(destination, max(visible.count - 1, 0))
        return true
    }

    func cancelEditing() {
        mode = .browsing
        draft = ""
        moveSelection = 0
        editingPinboardID = nil
    }
}
