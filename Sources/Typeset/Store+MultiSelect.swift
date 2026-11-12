import AppKit

// Multi-select on the Pages canvas (phase 7). The selection is a set (`selectionSet`): one item, or several on one
// page. With one item, `canvasSelection` names it and everything that works on one item works as before; with
// several, `canvasSelection` is nil, so no single item shows edges or takes a resize, crop or byline pull (rule 4),
// and moving, nudging and deleting act on the whole set. The pointer side is in Store+Pointer.swift: ⇧-click adds
// or removes an item, a drag from empty paper draws a marquee that selects only what it fully encloses, and
// dragging any item of the set moves the set, one undo step per gesture.
extension IssueStore {
    /// Selects exactly these items (all on one page): none clears, one selects it alone, several make a set.
    func select(_ items: Set<LayoutSelection>) {
        if items.count <= 1 {
            canvasSelection = items.first
            return
        }
        keepsSelectionSet = true
        canvasSelection = nil
        keepsSelectionSet = false
        if selectionSet != items { selectionSet = items }
    }

    var isMultiSelection: Bool { selectionSet.count > 1 }

    /// The page an item is on.
    func page(of item: LayoutSelection) -> Int? {
        for (i, p) in (issue.layout?.pages ?? []).enumerated() {
            switch item {
            case .block(let id): if p.stories.contains(where: { $0.id == id }) { return i }
            case .inset(let id): if p.insets.contains(where: { $0.id == id }) { return i }
            case .component(let id): if p.components.contains(where: { $0.id == id }) { return i }
            }
        }
        return nil
    }

    /// The page the selection is on (nil when nothing is selected).
    var selectionPage: Int? { selectionSet.lazy.compactMap { self.page(of: $0) }.first }

    /// An item's frame on its page, as stored (the frame a move changes).
    func storedFrame(_ item: LayoutSelection, on page: Int) -> CGRect? {
        guard let p = issue.layout?.pages[safe: page] else { return nil }
        switch item {
        case .block(let id): return p.stories.first { $0.id == id }?.frame.rect
        case .inset(let id): return p.insets.first { $0.id == id }?.frame.rect
        case .component(let id): return p.components.first { $0.id == id }?.frame.rect
        }
    }

    /// ⇧-click: the item joins the selection, or leaves it if it's already in. An item on another page than the
    /// selection starts a new selection there.
    func toggleSelection(_ item: LayoutSelection, on page: Int) {
        var set = selectionPage == page ? selectionSet : []
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
        select(set)
        focusedPage = page
    }

    /// What a marquee on a page takes: every item whose drawn shape (the hit test's) lies wholly inside it. An item
    /// it only brushes is left out.
    func enclosed(by rect: CGRect, on page: Int) -> Set<LayoutSelection> {
        guard rect.width > 0 || rect.height > 0 else { return [] }
        return Set(hitItems(on: page).filter { rect.contains($0.shape) }.map(\.selection))
    }

    /// The marquee let go: it selects what it encloses (with ⇧, added to what's selected on that page).
    func finishMarquee(_ rect: CGRect, on page: Int, adding: Bool) {
        var set = enclosed(by: rect, on: page)
        if adding, selectionPage == page { set.formUnion(selectionSet) }
        select(set)
        focusedPage = page
    }

    /// Drop selected items that have left the layout (after an undo, a removal).
    func pruneSelectionSet() {
        guard selectionSet.count > 1 else { return }
        let kept = selectionSet.filter { page(of: $0) != nil }
        if kept != selectionSet { select(kept) }
    }

    // MARK: moving the set

    /// Where every item of the set starts, on `page`: the selected items, and the pictures inside each selected
    /// story block (they move with it, as when the block moves alone).
    func groupStarts(on page: Int) -> [LayoutSelection: CGRect] {
        var out: [LayoutSelection: CGRect] = [:]
        for item in selectionSet {
            guard let r = storedFrame(item, on: page) else { continue }
            out[item] = r
            if case .block(let id) = item, let b = issue.layout?.pages[safe: page]?.stories.first(where: { $0.id == id }) {
                for i in insets(with: b, on: page) { out[.inset(i.id)] = i.frame.rect }
            }
        }
        return out
    }

    /// The box round the selected items' starts (the carried pictures lie inside their blocks).
    func groupBounds(_ starts: [LayoutSelection: CGRect]) -> CGRect {
        starts.values.reduce(CGRect.null) { $0.union($1) }
    }

    /// Moves every item of a group by (dx, dy) from where it started. A block keeps its place in the stacking
    /// order relative to the others (each one comes to the front, as a moved block does).
    func applyGroup(_ starts: [LayoutSelection: CGRect], page: Int, dx: CGFloat, dy: CGFloat) {
        // blocks first, in the order they're stacked, so their order among themselves is kept
        let order = (issue.layout?.pages[safe: page]?.stories.map(\.id)) ?? []
        let blocks = starts.keys.compactMap { if case .block(let id) = $0 { id } else { nil } }
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        for id in blocks { if let r = starts[.block(id)] { setBlockFrame(id, page: page, frame: r.offsetBy(dx: dx, dy: dy)) } }
        for (item, r) in starts {
            switch item {
            case .inset(let id): setInsetFrame(id, page: page, frame: r.offsetBy(dx: dx, dy: dy))
            case .component(let id): setComponentFrame(id, page: page, frame: r.offsetBy(dx: dx, dy: dy))
            case .block: break
            }
        }
    }

    /// The arrow keys with several items selected: they all move together, a point (ten with ⇧), stopping at the
    /// page's edge as one. One undo step.
    func nudgeSet(dx: CGFloat, dy: CGFloat) {
        guard let page = selectionPage else { return }
        let starts = groupStarts(on: page)
        let bounds = groupBounds(starts)
        guard !bounds.isNull else { return }
        let moved = onPage(bounds.offsetBy(dx: dx, dy: dy))
        let mx = moved.minX - bounds.minX, my = moved.minY - bounds.minY
        guard mx != 0 || my != 0 else { return }
        edit("Move Items") { applyGroup(starts, page: page, dx: mx, dy: my) }
    }

    /// Delete with several items selected: blocks, pictures and components all come off the page together. One undo step.
    func deleteSet() {
        let items = selectionSet
        guard !items.isEmpty, issue.layout != nil else { return }
        edit("Delete Items") { removeAll(items) }
        select([])
    }

    /// Takes items off every page (no undo step of its own: callers wrap it).
    func removeAll(_ items: Set<LayoutSelection>) {
        var blocks = Set<UUID>(), insets = Set<UUID>(), comps = Set<UUID>()
        for i in items {
            switch i {
            case .block(let id): blocks.insert(id)
            case .inset(let id): insets.insert(id)
            case .component(let id): comps.insert(id)
            }
        }
        for k in issue.layout!.pages.indices {
            issue.layout!.pages[k].stories.removeAll { blocks.contains($0.id) }
            issue.layout!.pages[k].insets.removeAll { insets.contains($0.id) }
            issue.layout!.pages[k].components.removeAll { comps.contains($0.id) }
        }
    }

    /// The set dragged into the inspector: stories go on hold, pictures and components come off the page, all in
    /// the drag's one undo step (the gesture's edit session is still open).
    func dropSetOutside(_ items: Set<LayoutSelection>) {
        var parked = Set<Article.ID>()
        for i in items { if case .block(let id) = i, let (_, b) = block(id) { parked.insert(b.article) } }
        removeAll(items.filter { if case .block = $0 { false } else { true } })
        for k in issue.layout!.pages.indices { issue.layout!.pages[k].stories.removeAll { parked.contains($0.article) } }
    }

    /// The set dropped on another page: each item goes there, offset as the group's preview shows, blocks carrying
    /// their pictures.
    func moveSet(_ starts: [LayoutSelection: CGRect], from: Int, to: Int, dx: CGFloat, dy: CGFloat) {
        let items = selectionSet
        for item in items { if case .block(let id) = item, let r = starts[item] { moveBlock(id, from: from, to: to, frame: r.offsetBy(dx: dx, dy: dy)) } }
        for item in items {
            switch item {
            case .inset(let id): if let r = starts[item] { moveInset(id, from: from, to: to, frame: r.offsetBy(dx: dx, dy: dy)) }
            case .component(let id): if let r = starts[item] { moveComponent(id, from: from, to: to, frame: r.offsetBy(dx: dx, dy: dy)) }
            case .block: break
            }
        }
        focusedPage = to
    }

    // MARK: Make Component… (phase 7): `makeComponent(from:name:)` is in Store+MakeComponent.swift

    /// Make Component…: asks for a name, then makes it, from the selection or (a right-click on an item that
    /// isn't selected) the one item. A single block, picture, pull quote or ad makes a component too.
    @MainActor
    func makeComponentCommand(_ only: LayoutSelection? = nil) {
        let items = only.map { [$0] } ?? selectionSet
        guard !items.isEmpty, items.contains(where: { if case .component = $0 { false } else { true } }) else { return }
        let alert = NSAlert()
        alert.messageText = "Make Component"
        alert.informativeText = items.count == 1 ? "\(name(of: items.first!)) becomes frames of a new component, placed where it is."
            : "The \(items.count) selected items become frames of a new component, placed where they are."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Component name"
        field.stringValue = "Untitled Component"
        alert.accessoryView = field
        alert.addButton(withTitle: "Make Component")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        makeComponent(from: items, name: name.isEmpty ? "Untitled Component" : name)
    }
}

extension LayoutSelection {
    /// The id of the block, picture or placed component it names.
    var itemID: UUID {
        switch self { case .block(let id): id; case .inset(let id): id; case .component(let id): id }
    }
}
