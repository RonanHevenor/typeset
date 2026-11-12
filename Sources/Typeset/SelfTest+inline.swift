import AppKit

/// Phase 7 checks: multi-select on the Pages canvas (⇧-click, a marquee that takes only what it fully encloses,
/// moving, nudging and deleting the set, one undo step each, a lost drag) and the in-place editor (double-click
/// opens it, the page takes no clicks while it's open, leaving makes the placement custom, Save as New Version,
/// Revert, undo past its start). Driven through the store's pointer state machine and the editor's at page points,
/// under phase 2's six rules. Built on two cleared inside pages of the seed issue; everything is put back.
extension SelfTest {
    @MainActor
    static func inlineChecks(_ store: IssueStore, data: URL, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3 else { check("inline: a generated issue with three pages", false); return }
        let stories = store.issue.articles.filter { $0.body.count > 3 }
        guard stories.count >= 2 else { check("inline: two stories", false); return }

        // one undo step per command, in a group of its own (see SelfTest.undoStep)
        let saved = store.issue, savedZoom = store.zoom, savedUndo = store.undoManager
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.zoom = 1
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        defer {
            store.closeInPlace()
            step { store.pointerCancelled() }
            store.issue = saved; store.zoom = savedZoom; store.undoManager = savedUndo; store.select([])
        }
        let pg = layout.pages.count - 1, pg2 = layout.pages.count - 2
        let g = store.grid
        let A = StoryBlock(article: stories[0].id, frame: Box(x: g.x(0), y: 120, w: g.colWidth, h: 220), columns: 1,
                           headlineSize: HouseStyle.headlineSize(columns: 1))
        let B = StoryBlock(article: stories[1].id, frame: Box(x: g.x(1), y: 120, w: g.colWidth, h: 220), columns: 1,
                           headlineSize: HouseStyle.headlineSize(columns: 1))
        let head = Frame(type: .headline, box: Box(x: 0, y: 0, w: 200, h: 30), link: "A", size: 20)
        let shape = ShapeElement(box: Box(x: 10, y: 40, w: 60, h: 40), fill: .red)
        let v1 = ComponentVersion(number: 1, width: 200, height: 100, elements: [.frame(head), .rect(shape)])
        let v2 = ComponentVersion(number: 2, width: 200, height: 100, elements: [.frame(head)])
        let card = Component(name: "Inline Card", versions: [v1, v2])
        let cOrigin = CGPoint(x: g.x(0), y: 420)
        var cid = UUID()
        step { store.edit("Stage") {
            for i in [pg, pg2] {
                store.issue.layout!.pages[i].stories = []
                store.issue.layout!.pages[i].insets = []
                store.issue.layout!.pages[i].components = []
            }
            store.issue.layout!.pages[pg].stories = [A, B]
            store.issue.embed(card, version: 2)
            cid = store.issue.place(card, version: 1, on: pg, at: cOrigin) ?? cid
        } }
        func fresh() { step { store.pointerCancelled() }; undo.removeAllActions(); store.select([]) }
        func click(_ p: CGPoint, on page: Int? = nil, mods: IssueStore.PointerModifiers = [], count: Int = 1) { step {
            store.pointerDown(at: p, on: page ?? pg, modifiers: mods, clickCount: count)
            store.pointerUp(at: .page(page ?? pg, p), modifiers: mods)
        } }
        func drag(_ from: CGPoint, by d: CGSize, on page: Int? = nil, to target: IssueStore.PointerLocation? = nil, mods: IssueStore.PointerModifiers = []) { step {
            let page = page ?? pg
            store.pointerDown(at: from, on: page, modifiers: mods)
            store.pointerMoved(to: .page(page, CGPoint(x: from.x + d.width / 2, y: from.y + d.height / 2)), modifiers: mods)
            let to = target ?? .page(page, CGPoint(x: from.x + d.width, y: from.y + d.height))
            store.pointerMoved(to: to, modifiers: mods)
            store.pointerUp(at: to, modifiers: mods)
        } }
        func frame(_ item: LayoutSelection) -> CGRect? { store.page(of: item).flatMap { store.storedFrame(item, on: $0) } }
        func r(_ x: CGRect?) -> String { x.map { String(format: "%.1f,%.1f %.1fx%.1f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none" }
        func near(_ x: CGRect?, _ y: CGRect, _ e: CGFloat = 0.01) -> Bool {
            guard let x else { return false }
            return abs(x.minX - y.minX) < e && abs(x.minY - y.minY) < e && abs(x.width - y.width) < e && abs(x.height - y.height) < e
        }
        let a: LayoutSelection = .block(A.id), b: LayoutSelection = .block(B.id), c: LayoutSelection = .component(cid)
        guard let fa = frame(a), let fb = frame(b), let fc = frame(c) else { check("inline: staged two blocks and a component", false); return }
        let pa = CGPoint(x: fa.midX, y: fa.midY), pb = CGPoint(x: fb.midX, y: fb.midY), pc = CGPoint(x: fc.midX, y: fc.midY)
        let empty = CGPoint(x: fa.minX + 10, y: fc.maxY + 80)
        func sel(_ s: Set<LayoutSelection>) -> String { "\(s.count) selected: " + s.map { $0 == a ? "A" : $0 == b ? "B" : $0 == c ? "C" : "?" }.sorted().joined() }

        // MARK: ⇧-click

        fresh()
        click(pa)
        check("multi: a click selects one item", store.canvasSelection == a && store.selectionSet == [a], sel(store.selectionSet))
        click(pb, mods: [.shift])
        check("multi: ⇧-click adds an item: the set is two, no single item is selected", store.selectionSet == [a, b] && store.canvasSelection == nil, sel(store.selectionSet))
        click(pc, mods: [.shift])
        check("  ⇧-click a component adds it too", store.selectionSet == [a, b, c], sel(store.selectionSet))
        click(pb, mods: [.shift])
        check("  ⇧-click a selected item takes it out", store.selectionSet == [a, c], sel(store.selectionSet))
        click(empty, mods: [.shift])
        check("  ⇧-click on empty paper keeps the selection", store.selectionSet == [a, c], sel(store.selectionSet))
        store.pointerHover(at: pb, on: pg)
        check("rule 1: hovering never changes the set", store.selectionSet == [a, c])
        let edgeOfA = CGPoint(x: fa.maxX + 2, y: fa.midY)
        check("rule 4: with several selected, no item has edges", store.hit(at: edgeOfA, on: pg).edge == nil && store.hit(at: CGPoint(x: fc.maxX + 2, y: fc.midY), on: pg).edge == nil)
        click(pa)
        check("  a plain click on one of them selects it alone", store.selectionSet == [a] && store.canvasSelection == a, sel(store.selectionSet))
        click(pa, mods: [.shift])
        check("  ⇧-click the only selected item leaves nothing selected", store.selectionSet.isEmpty && store.canvasSelection == nil, sel(store.selectionSet))
        click(pa); click(pb, mods: [.shift])
        click(pa, on: pg2, mods: [.shift])          // empty paper on another page: no item there
        check("  ⇧-click on another page's empty paper changes nothing", store.selectionSet == [a, b], sel(store.selectionSet))
        click(empty)
        check("rule 1: a click on empty paper clears the set", store.selectionSet.isEmpty)

        // MARK: the marquee

        fresh()
        let around = (from: CGPoint(x: fa.minX - 8, y: fa.minY - 8), to: CGPoint(x: fb.maxX + 6, y: fb.maxY + 6))
        drag(around.from, by: CGSize(width: around.to.x - around.from.x, height: around.to.y - around.from.y))
        check("marquee: a drag from empty paper selects what it fully encloses", store.selectionSet == [a, b], sel(store.selectionSet))
        check("rule 1: the marquee picks nothing up: what it crossed hasn't moved", near(frame(a), fa) && near(frame(b), fb) && near(frame(c), fc) && !undo.canUndo)
        let brush = (from: CGPoint(x: fa.minX - 8, y: fa.minY - 8), to: CGPoint(x: fb.midX, y: fc.midY))
        drag(brush.from, by: CGSize(width: brush.to.x - brush.from.x, height: brush.to.y - brush.from.y))
        check("marquee: what it only brushes isn't taken (B and the component half in), what it encloses is (A)",
              store.selectionSet == [a], sel(store.selectionSet))
        drag(CGPoint(x: fa.minX - 20, y: fa.midY), by: CGSize(width: 40, height: 20))   // clear of A's edge band
        check("  one that encloses nothing selects nothing, and moves nothing", store.selectionSet.isEmpty && near(frame(a), fa), sel(store.selectionSet))
        click(pc)
        drag(around.from, by: CGSize(width: fa.width + 16, height: fa.height + 16), mods: [.shift])
        check("  with ⇧ it adds what it encloses to the selection", store.selectionSet == [a, c], sel(store.selectionSet))
        let pm = store.pointer
        check("  and the gesture closes: nothing mid-drag", !pm.isActive && pm.marquee == nil && !store.editingNow)

        // MARK: moving the set

        fresh()
        click(pa); click(pb, mods: [.shift])
        drag(pa, by: CGSize(width: 0, height: 40), mods: [.command])
        check("multi move: dragging one of the set moves them all (⌘: no snapping)",
              near(frame(a), fa.offsetBy(dx: 0, dy: 40)) && near(frame(b), fb.offsetBy(dx: 0, dy: 40)) && near(frame(c), fc), "A \(r(frame(a))) B \(r(frame(b)))")
        check("  the set stays selected", store.selectionSet == [a, b], sel(store.selectionSet))
        undo.undo()
        check("  one undo step puts them both back", near(frame(a), fa) && near(frame(b), fb) && !undo.canUndo, "A \(r(frame(a))) B \(r(frame(b)))")
        drag(pb, by: CGSize(width: 30, height: 4), mods: [.command, .shift])
        check("  ⇧ holds the set to one axis", near(frame(a), fa.offsetBy(dx: 30, dy: 0)) && near(frame(b), fb.offsetBy(dx: 30, dy: 0)), "A \(r(frame(a)))")
        undo.undo()
        drag(pa, by: CGSize(width: 2, height: 1))
        check("  a move under the threshold is a click: it selects that one item, nothing moves", store.selectionSet == [a] && near(frame(a), fa), sel(store.selectionSet))
        click(pb, mods: [.shift])
        drag(pc, by: CGSize(width: 20, height: 20), mods: [.command])
        check("rule 1: dragging an item outside the set selects it alone and moves only it",
              store.selectionSet == [c] && near(frame(c), fc.offsetBy(dx: 20, dy: 20)) && near(frame(a), fa) && near(frame(b), fb), sel(store.selectionSet))
        undo.undo()

        // onto another page, into the inspector, and a lost drag
        fresh()
        click(pa); click(pb, mods: [.shift])
        drag(pa, by: CGSize(width: 10, height: 10), to: .page(pg2, CGPoint(x: pa.x + 10, y: pa.y + 10)), mods: [.command])
        check("multi move: the set dragged onto another page goes there together, one undo step",
              store.page(of: a) == pg2 && store.page(of: b) == pg2 && store.page(of: c) == pg, "A on \(store.page(of: a).map { $0 + 1 } ?? 0), B on \(store.page(of: b).map { $0 + 1 } ?? 0)")
        undo.undo()
        check("  and comes back with one undo", store.page(of: a) == pg && store.page(of: b) == pg && near(frame(a), fa) && near(frame(b), fb) && !undo.canUndo)
        fresh()
        click(pa); click(pc, mods: [.shift])
        drag(pa, by: CGSize(width: 10, height: 0), to: .inspector)
        check("multi move: the set dropped in the inspector: the story goes on hold, the component comes off, one undo step",
              store.page(of: a) == nil && store.page(of: c) == nil && store.page(of: b) == pg && store.selectionSet.isEmpty)
        undo.undo()
        check("  one undo puts both back", near(frame(a), fa) && near(frame(c), fc) && !undo.canUndo)
        fresh()
        click(pa); click(pb, mods: [.shift])
        step {
            store.pointerDown(at: pa, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: pa.x + 25, y: pa.y)), modifiers: [.command])
            store.pointerCancelled()
        }
        check("rule 6: a set whose mouse-up is lost stays where it was dropped, nothing mid-drag, one undo step",
              near(frame(a), fa.offsetBy(dx: 25, dy: 0)) && near(frame(b), fb.offsetBy(dx: 25, dy: 0)) && !store.pointer.isActive && !store.editingNow && store.dragging == nil,
              "A \(r(frame(a)))")
        undo.undo()
        check("  (one undo puts it back)", near(frame(a), fa) && near(frame(b), fb) && !undo.canUndo)

        // MARK: nudge and delete

        fresh()
        click(pa); click(pc, mods: [.shift])
        step { store.nudge(dx: 10, dy: 0) }
        check("multi nudge: the arrow keys move the whole set", near(frame(a), fa.offsetBy(dx: 10, dy: 0)) && near(frame(c), fc.offsetBy(dx: 10, dy: 0)) && near(frame(b), fb))
        undo.undo()
        check("  one undo step puts them back", near(frame(a), fa) && near(frame(c), fc) && !undo.canUndo)
        step { store.nudge(dx: -2000, dy: 0) }
        check("  the set stops at the page edge as one", (frame(a)?.minX ?? -1) == 0 && abs((frame(c)?.minX ?? -1) - (fc.minX - fa.minX)) < 0.01, r(frame(a)))
        undo.undo()
        step { store.deleteSelection() }
        check("multi delete: Delete removes the whole set and leaves the rest", frame(a) == nil && frame(c) == nil && near(frame(b), fb) && store.selectionSet.isEmpty)
        undo.undo()
        check("  one undo step brings both back", near(frame(a), fa) && near(frame(c), fc) && !undo.canUndo)

        // MARK: the in-place editor

        fresh()
        click(pc)
        click(pc, count: 2)
        guard let ip = store.inPlace, let e = Optional(ip.editor) else { check("in place: a double-click on a placed component opens it in place", false); return }
        check("in place: a double-click on a placed component opens it in place, the page's selection let go",
              ip.placed == cid && ip.page == pg && store.selectionSet.isEmpty)
        check("  the editor shows the component where it's placed, as drawn",
              e.origin == fc.origin && e.draft.sameContent(as: v1) && e.base == 1 && e.pageIndex == pg, "origin \(e.origin) base \(String(describing: e.base))")
        // the paper underneath takes no clicks, hover or drags (rule 1, rule 3)
        click(pa)
        check("in place: a click on a story on the page selects nothing", store.selectionSet.isEmpty && !store.pointer.isActive)
        drag(pb, by: CGSize(width: 30, height: 0), mods: [.command])
        check("  a drag on the page moves nothing", near(frame(b), fb) && store.selectionSet.isEmpty)
        check("  hovering the page finds nothing", store.pointerHover(at: pa, on: pg) == nil)
        let pv = PageDropView(frame: CGRect(x: 0, y: 0, width: HouseStyle.page.width, height: HouseStyle.page.height))
        pv.store = store; pv.index = pg
        check("  the page's pointer view lets presses through to the editor", !pv.takesPress(at: pa))
        check("  the edit isn't an undo step yet", !undo.canUndo)

        // the editor: phase 6's pointer, on the page
        let shapeRect = e.pageRect(.rect(shape))
        let ps = CGPoint(x: shapeRect.midX, y: shapeRect.midY)
        step { e.pointerDown(at: ps); e.pointerUp(at: ps) }
        check("in place: a click on an element selects it, through the editor's hit test", e.selection == .element(shape.id), "\(String(describing: e.selection))")
        step { e.pointerDown(at: ps); e.pointerMoved(to: CGPoint(x: ps.x + 10, y: ps.y), modifiers: [.command]); e.pointerMoved(to: CGPoint(x: ps.x + 20, y: ps.y), modifiers: [.command]); e.pointerUp(at: CGPoint(x: ps.x + 20, y: ps.y), modifiers: [.command]) }
        check("  dragging it moves it, one undo step in the window's undo",
              abs((e.element(shape.id)?.box.x ?? 0) - (shape.box.x + 20)) < 0.01 && undo.canUndo, "x \(e.element(shape.id)?.box.x ?? -1)")
        undo.undo()
        check("  undo puts it back", abs((e.element(shape.id)?.box.x ?? 0) - shape.box.x) < 0.01)
        undo.redo()
        let off = CGPoint(x: fc.maxX + 60, y: fc.maxY + 60)
        step { e.pointerDown(at: off); e.pointerUp(at: off) }
        check("  a click on the faded page outside the component clears the editor's selection", e.selection == nil)

        // leaving: the placement is custom, one undo step
        step { store.leaveInPlace() }
        let p1 = store.placedComponent(cid)?.placed
        check("in place: leaving makes the placement custom (\"Inline Card custom\"), the component selected",
              store.inPlace == nil && p1?.custom != nil && p1.map { store.componentLabel($0) } == "Inline Card custom" && store.canvasSelection == c,
              p1.map { store.componentLabel($0) } ?? "gone")
        let customRect = p1?.custom?.elements.first { $0.id == shape.id }?.box
        check("  its copy has the edit; the version it came from doesn't", abs((customRect?.x ?? 0) - (shape.box.x + 20)) < 0.01 && p1?.version == 1
              && store.issue.componentVersions.first { $0.id == card.id }?.version(1)?.sameContent(as: v1) == true)
        check("  the sidebar row says custom", store.componentRuns(card.id) == ["Page \(pg + 1) · custom"], "\(store.componentRuns(card.id))")
        check("  the editor's own steps are folded into one", undo.canUndo && undo.undoActionName.contains("in Place"), undo.undoActionName)
        undo.undo()
        check("  one undo step makes it v1 again", store.placedComponent(cid)?.placed.custom == nil)
        undo.redo()
        check("  and redo makes it custom again", store.placedComponent(cid)?.placed.custom != nil)

        // Revert to v1
        fresh()
        step { store.revertCustom(cid) }
        check("Revert to v1: the placement draws v1 again, same place", store.placedComponent(cid)?.placed.custom == nil
              && store.placedComponent(cid).map { store.componentLabel($0.placed) } == "Inline Card v1" && near(frame(c), fc))
        undo.undo()
        check("  one undo step makes it custom again", store.placedComponent(cid)?.placed.custom != nil)

        // Save as New Version
        let url = data.appendingPathComponent("inline-card.typesetcomponent")
        try? FileManager.default.removeItem(at: url)
        let ok = step { store.saveCustomAsNewVersion(cid, to: url) }
        let p3 = store.placedComponent(cid)?.placed
        let saved3 = try? ComponentFiles.read(url)
        check("Save as New Version: the copy becomes v3, written to the component's file, and the placement shows it",
              ok && p3?.custom == nil && p3?.version == 3 && p3.map { store.componentLabel($0) } == "Inline Card v3"
              && saved3?.versions.map(\.number) == [1, 2, 3] && saved3?.version(3)?.elements == customRectElements(p1),
              "\(saved3?.versions.map(\.number) ?? [])")
        check("  the issue keeps a copy of v3 and still draws it in place", p3.flatMap { store.issue.version(of: $0) }?.number == 3 && near(frame(c), fc))
        undo.undo()
        check("  one undo step makes it custom again", store.placedComponent(cid)?.placed.custom != nil)
        try? FileManager.default.removeItem(at: url)

        // leaving with nothing changed keeps the version; a stretched placement opens as it's drawn
        fresh()
        step { store.revertCustom(cid) }
        undo.removeAllActions()
        step { store.setComponentFrame(cid, page: pg, frame: CGRect(x: fc.minX, y: fc.minY, width: fc.width * 2, height: fc.height)) }
        undo.removeAllActions()
        step { _ = store.enterInPlace(cid) }
        let e2 = store.inPlace?.editor
        let stretchedShape = e2?.element(shape.id)?.box
        check("in place: a stretched placement opens as drawn (its boxes stretched, at its size)",
              e2?.draft.width == fc.width * 2 && abs((stretchedShape?.x ?? 0) - shape.box.x * 2) < 0.01 && abs((stretchedShape?.w ?? 0) - shape.box.w * 2) < 0.01,
              "\(e2?.draft.width ?? -1) × \(e2?.draft.height ?? -1)")
        step { store.leaveInPlace() }
        check("  leaving with nothing changed leaves it as it was: v1, not custom, no undo step",
              store.placedComponent(cid)?.placed.custom == nil && store.placedComponent(cid)?.placed.version == 1 && !undo.canUndo)

        // undo past where the editor opened closes it
        fresh()
        let placedNew = step { store.placeComponent(card.id, version: 2, on: pg2) }
        if let placedNew {
            step { _ = store.enterInPlace(placedNew) }
            check("in place: opened on a component placed a moment ago", store.inPlace?.placed == placedNew)
            undo.undo()                                           // the placing: the component leaves the page
            check("  undo that takes the component off the page closes the editor", store.inPlace == nil && store.placedComponent(placedNew) == nil)
        } else {
            check("in place: placing a second component for the undo check", false)
        }
        step { _ = store.enterInPlace(cid) }
        step { store.edit("Clear") { store.issue.layout!.pages[pg].components = [] } }    // as Generate or Clear Pages would
        store.followInPlace()                                                             // the canvas calls it on any layout change
        check("in place: a menu command that takes the component away closes the editor", store.inPlace == nil)
        undo.undo()
        check("in place: the pages take clicks again once it's closed", { click(pa); return store.canvasSelection == a }())
    }

    /// The elements of a placement's custom copy (for comparing with what was saved).
    private static func customRectElements(_ p: PlacedComponent?) -> [Element]? { p?.custom?.elements }
}
