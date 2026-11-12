import AppKit

/// Phase 2 (canvas interaction) checks: the hit test and the pointer state machine driven at page points, one for
/// each pointer bug in `repro/notes/interaction-bugs.md (kept locally, not in git)` the store side can show (IB-n), plus the reviewers' cases:
/// overlapping items, a picture over a story, zoomed in and out, the page edge, a drag across two pages, a lost
/// mouse-up. Everything is built on two cleared inside pages of the generated seed issue, so the geometry is known.
extension SelfTest {
    @MainActor
    static func canvasChecks(_ store: IssueStore, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3,
              let a0 = store.issue.articles.first(where: { !$0.photos.isEmpty && $0.body.count > 5 }),
              let a1 = store.issue.articles.first(where: { $0.id != a0.id && !$0.photos.isEmpty && $0.body.count > 5 }) else {
            check("canvas: a generated issue with two illustrated stories to test on", false, "none"); return
        }
        let pg = layout.pages.count - 1, pg2 = layout.pages.count - 2
        let savedZoom = store.zoom
        store.zoom = 1
        defer { store.zoom = savedZoom }
        let g = store.grid
        let savedUndo = store.undoManager
        let undo = UndoManager()
        store.undoManager = undo
        defer { store.undoManager = savedUndo }
        func fresh() { undo.removeAllActions(); store.canvasSelection = nil; store.pointerCancelled() }
        func frame(_ id: StoryBlock.ID) -> CGRect? { store.block(id)?.block.frame.rect }
        func inset(_ id: Inset.ID) -> (page: Int, inset: Inset)? {
            for (i, p) in (store.issue.layout?.pages ?? []).enumerated() { if let x = p.insets.first(where: { $0.id == id }) { return (i, x) } }
            return nil
        }
        func shape(_ id: Inset.ID, on page: Int) -> CGRect? { store.hitItems(on: page).first { $0.selection == .inset(id) }?.shape }
        func drag(_ from: CGPoint, by d: CGSize, on page: Int, to target: Int? = nil, mods: IssueStore.PointerModifiers = []) {
            store.pointerDown(at: from, on: page, modifiers: mods)
            let to = CGPoint(x: from.x + d.width, y: from.y + d.height)
            store.pointerMoved(to: .page(target ?? page, CGPoint(x: from.x + d.width / 2, y: from.y + d.height / 2)), modifiers: mods)
            store.pointerMoved(to: .page(target ?? page, to), modifiers: mods)
            store.pointerUp(at: .page(target ?? page, to), modifiers: mods)
        }
        func r(_ x: CGRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", x.minX, x.minY, x.width, x.height) }

        // the stage: story A (2 columns) with its photo P flush right inside it, story B below, on a cleared page
        store.clearPage(pg); store.clearPage(pg2)
        store.undoManager = undo
        guard let A = store.addBlock(a0.id, on: pg, at: CGPoint(x: 40, y: 100)),
              let B = store.addBlock(a1.id, on: pg, at: CGPoint(x: 40, y: 700)) else { check("canvas: two blocks placed", false, ""); return }
        let fA = CGRect(x: g.x(0), y: 100, width: g.span(2), height: 500)
        let fB = CGRect(x: g.x(0), y: 700, width: g.span(2), height: 300)
        store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: fA); store.setBlockFrame(B, page: pg, frame: fB) }
        guard let P = store.placePhoto(a0.photos[0].id, of: a0.id, on: pg, in: A) else { check("canvas: photo placed", false, ""); return }
        let fP = CGRect(x: fA.maxX - g.span(1), y: 250, width: g.span(1), height: 150)
        store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: fP) }
        _ = store.displayPages
        guard let sP = shape(P, on: pg) else { check("canvas: photo shape", false, ""); return }
        check("canvas: a photo's hit shape is its picture plus its caption", sP.minX == fP.minX && sP.minY == fP.minY && sP.width == fP.width && sP.height >= fP.height, r(sP))
        fresh()

        // rule 1 / IB-1: a click with a 2 pt wobble on an unselected, off-grid photo only selects it
        do {
            let off = fP.offsetBy(dx: 5, dy: 3)
            store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: off) }
            fresh()
            let c = CGPoint(x: off.midX, y: off.midY)
            store.pointerDown(at: c, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: c.x + 2, y: c.y + 1)))
            check("IB-1 a 2 pt wobble is still a click: nothing picked up", store.pointer.phase == .pressed && !store.editingNow, "\(store.pointer.phase)")
            store.pointerUp(at: .page(pg, CGPoint(x: c.x + 2, y: c.y + 1)))
            check("IB-1 the click selects the photo and nothing moves or snaps", store.canvasSelection == .inset(P) && inset(P)?.inset.frame.rect == off,
                  inset(P).map { r($0.inset.frame.rect) } ?? "gone")
            check("IB-1 no undo step for a click", !undo.canUndo, undo.undoActionName)
            store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: fP) }
        }
        fresh()

        // rule 1: dragging an unselected photo selects it and moves it, one undo step; hover changes nothing
        do {
            store.canvasSelection = .block(A)
            store.pointerHover(at: CGPoint(x: fP.midX, y: fP.midY), on: pg)
            check("hovering a photo leaves the story selected", store.canvasSelection == .block(A))
            drag(CGPoint(x: fP.midX, y: fP.midY), by: CGSize(width: -60, height: 0), on: pg, mods: [.command])
            let now = inset(P)?.inset.frame.rect
            check("a drag on an unselected photo selects it and moves it (Keynote)", store.canvasSelection == .inset(P) && now == fP.offsetBy(dx: -60, dy: 0), now.map(r) ?? "gone")
            check("  one undo step named Move Photo", undo.canUndo && undo.undoActionName == "Move Photo", undo.undoActionName)
            undo.undo()
            check("  undo puts it back in one step and keeps the selection (IB-3)", inset(P)?.inset.frame.rect == fP && !undo.canUndo && store.canvasSelection == .inset(P))
            check("  the gesture is over", !store.pointer.isActive && store.dragging == nil && !store.editingNow)
        }
        fresh()

        // rule 1: a click on empty paper clears; a drag that ends elsewhere never changes the selection; a drag
        // from empty paper is a marquee and picks nothing up
        do {
            store.canvasSelection = .block(A)
            let empty = CGPoint(x: 400, y: 1100)
            check("empty paper is empty", !store.hit(at: empty, on: pg).isItem, "\(store.hit(at: empty, on: pg).what)")
            drag(empty, by: .zero, on: pg)
            check("a click on empty paper clears the selection", store.canvasSelection == nil)
            store.canvasSelection = .block(A)
            drag(CGPoint(x: fA.minX + 30, y: fA.minY + 30), by: CGSize(width: 0, height: 620), on: pg, mods: [.command])
            check("a drag that ends over another story keeps the dragged story selected", store.canvasSelection == .block(A))
            undo.undo()
            store.canvasSelection = .block(A)
            store.pointerDown(at: empty, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: fB.midX, y: fB.midY)))
            check("a drag from empty paper is a marquee: nothing grabbed, selection kept", store.pointer.phase == .marquee && store.pointer.marquee != nil
                  && store.canvasSelection == .block(A) && store.dragging == nil, "\(store.pointer.phase)")
            // letting go selects what the marquee wholly encloses (phase 7 multi-select): here it only reaches B's
            // middle, so B isn't taken, and what was selected before is replaced
            let enclosed = store.enclosed(by: store.pointer.marquee ?? .null, on: pg)
            store.pointerUp(at: .page(pg, CGPoint(x: fB.midX, y: fB.midY)))
            check("  nothing moved, no undo step; it selects only what it enclosed", frame(B) == fB && !undo.canUndo
                  && store.selectionSet == enclosed && !enclosed.contains(.block(B)),
                  "B moved \(frame(B) != fB), canUndo \(undo.canUndo), selected \(store.selectionSet), enclosed \(enclosed)")
        }
        fresh()

        // rule 3 / IB-5: a picture on a selected story is on top: its inside edge belongs to the picture
        do {
            store.canvasSelection = .block(A)
            let p = CGPoint(x: fP.maxX - 3, y: fP.midY)
            let h = store.hit(at: p, on: pg)
            check("IB-5 3 pt inside the photo's right edge is the photo, not the story's edge", h.what == .inset(P) && h.edge == nil, "\(h.what) \(String(describing: h.edge))")
            check("  the cursor there is the open hand", h.cursor == .openHand)
            drag(p, by: CGSize(width: -40, height: 0), on: pg, mods: [.command])
            check("  a drag there moves the photo and leaves the story", store.canvasSelection == .inset(P) && inset(P)?.inset.frame.rect == fP.offsetBy(dx: -40, dy: 0) && frame(A) == fA)
            undo.undo()
            store.canvasSelection = .block(A)
            let h2 = store.hit(at: CGPoint(x: fA.maxX - 3, y: fA.minY + 40), on: pg)
            check("  above the photo the story's own right edge is live", h2.what == .block(A) && h2.edge == .e, "\(h2.what) \(String(describing: h2.edge))")
        }
        fresh()

        // rule 4 / IB-9: a selected picture's band reaches the same distance either side of its edge, over the story it sits on
        do {
            store.canvasSelection = .inset(P)
            let w = store.hit(at: CGPoint(x: fP.minX - 3, y: fP.midY), on: pg)
            let n = store.hit(at: CGPoint(x: fP.midX, y: fP.minY - 3), on: pg)
            let e = store.hit(at: CGPoint(x: fP.maxX + 3, y: fP.midY), on: pg)
            let inside = store.hit(at: CGPoint(x: fP.minX + 3, y: fP.midY), on: pg)
            check("IB-9 3 pt outside a selected photo's left, top and right edges still holds the edge", w.edge == .w && n.edge == .n && e.edge == .e && inside.edge == .w,
                  "\(String(describing: w.edge)) \(String(describing: n.edge)) \(String(describing: e.edge))")
            check("  a story the picture sits on is not a neighbour: the hit is still the photo", w.what == .inset(P))
        }
        fresh()

        // rule 3 / IB-6: a story laid out later wins the overlap, whatever is selected
        do {
            let over = fB.offsetBy(dx: 0, dy: -200)                         // B now runs y500..800 over A's bottom (y600)
            store.edit("Stage") { store.setBlockFrame(B, page: pg, frame: over) }
            store.canvasSelection = .block(A)
            let p = CGPoint(x: fA.minX + 60, y: fA.maxY - 30)
            let h = store.hit(at: p, on: pg)
            check("IB-6 inside the overlap the later story is under the pointer", h.what == .block(B) && h.edge == nil, "\(h.what)")
            let edge = store.hit(at: CGPoint(x: fA.minX + 60, y: fA.maxY - 3), on: pg)
            check("  the selected story's bottom edge yields where the later story covers it", edge.edge == nil && edge.what == .block(B), "\(String(describing: edge.edge))")
            drag(p, by: .zero, on: pg)
            check("  a click there selects the later story", store.canvasSelection == .block(B))
            store.canvasSelection = .block(A)
            let outside = store.hit(at: CGPoint(x: fA.maxX + 3, y: fA.minY + 40), on: pg)
            check("  the selected story's edge is live where nothing covers it, and the hit is the story", outside.edge == .e && outside.what == .block(A))
            let below = store.hit(at: CGPoint(x: fB.minX + 60, y: over.maxY + 3), on: pg)
            check("  and over a neighbour outside its frame it yields", below.edge == nil, "\(String(describing: below.edge))")
            store.edit("Stage") { store.setBlockFrame(B, page: pg, frame: fB) }
        }
        fresh()

        // rule 3 / IB-7: the front-page teasers are frames of the Header component since phase 4; the component's
        // hit test (phase 5) carries this check over: SelfTest+placing.swift, "IB-7 the Header over a selected story's top band"
        fresh()

        // rule 4 / IB-8: what the pointer holds is worked out from the current geometry at the press
        do {
            store.canvasSelection = .block(A)
            let p = CGPoint(x: fA.maxX - 3, y: fA.minY + 40)
            store.pointerHover(at: p, on: pg)
            check("IB-8 hovering the selected story's right edge shows it", store.hoverZone == .e)
            store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: fA.offsetBy(dx: 40, dy: 0)) }
            store.refreshHover()
            check("  after a nudge the hovered edge is worked out again", store.hoverZone == nil, "\(String(describing: store.hoverZone))")
            store.pointerDown(at: p, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: p.x + 30, y: p.y)))
            check("  a press there now moves the story instead of pulling its old edge", store.pointer.phase == .dragging, "\(store.pointer.phase)")
            store.pointerUp(at: .page(pg, CGPoint(x: p.x + 30, y: p.y)))
            undo.undo(); undo.undo()
            check("  (stage restored)", frame(A) == fA, frame(A).map(r) ?? "gone")
            store.canvasSelection = nil
            store.pointerHover(at: p, on: pg)
            check("  an unselected story has no edges", store.hoverZone == nil)
            drag(p, by: .zero, on: pg)
            store.pointerDown(at: p, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: p.x + 30, y: p.y)))
            check("  select by a click, then press on the same spot: it's the edge now", store.canvasSelection == .block(A) && store.pointer.phase == .resizing && store.pointer.zone == .e, "\(store.pointer.phase)")
            store.pointerUp(at: .page(pg, CGPoint(x: p.x + 30, y: p.y)))
            undo.undo()
        }
        fresh()

        // rule 4 / IB-10: at the page edge the outer half of the band is still the edge
        do {
            let flush = CGRect(x: 0, y: fA.minY, width: fA.width, height: fA.height)
            store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: flush) }
            store.canvasSelection = .block(A)
            let h = store.hit(at: CGPoint(x: -3, y: flush.midY), on: pg)
            check("IB-10 3 pt beyond the page's left edge still holds the flush story's left edge", h.edge == .w && !h.onPage, "\(String(describing: h.edge)) onPage \(h.onPage)")
            undo.undo()
            check("  (stage restored)", frame(A) == fA)
        }
        fresh()

        // rule 4 / IB-11: the byline grip is a small capsule on the byline's edge and reaches over no neighbour
        do {
            store.canvasSelection = .block(A)
            _ = store.displayPages
            if let grip = store.hitItems(on: pg).first(where: { $0.selection == .block(A) })?.grip {
                let on = store.hit(at: CGPoint(x: grip.midX, y: grip.midY), on: pg)
                let off = store.hit(at: CGPoint(x: grip.maxX + 10, y: grip.midY), on: pg)
                check("IB-11 the grip is hit at its capsule and its cursor is left-right", on.what == .bylineGrip(A) && on.cursor == .resizeLeftRight, "\(on.what)")
                check("  10 pt right of the capsule is not the grip", off.what != .bylineGrip(A), "\(off.what)")
                check("  the capsule is 9 x 22 screen points", abs(grip.width - 9) < 0.01 && abs(grip.height - 22) < 0.01, r(grip))
                store.canvasSelection = nil
                check("  an unselected story has no grip", store.hit(at: CGPoint(x: grip.midX, y: grip.midY), on: pg).what != .bylineGrip(A))
            } else {
                check("IB-11 a 2-column story has a byline grip", false, "no grip")
            }
        }
        fresh()
        canvasGripChecks(report)
        canvasLostUpChecks(store, page: pg, photo: P, undo: undo, report)
        fresh()

        // rule 5 / IB-15: the grip sets the width from where the drag began, not from the live byline
        do {
            store.canvasSelection = .block(A)
            if let grip = store.hitItems(on: pg).first(where: { $0.selection == .block(A) })?.grip {
                let c = CGPoint(x: grip.midX, y: grip.midY)
                let pull = 0.6 * (g.colWidth + HouseStyle.gutter)
                store.pointerDown(at: c, on: pg)
                store.pointerMoved(to: .page(pg, CGPoint(x: c.x + pull, y: c.y)))
                let first = store.block(A)?.block.bylineColumns
                store.pointerMoved(to: .page(pg, CGPoint(x: c.x + pull, y: c.y)))
                store.pointerMoved(to: .page(pg, CGPoint(x: c.x + pull + 1, y: c.y)))
                let again = store.block(A)?.block.bylineColumns
                check("IB-15 pulling the grip a little over half a column makes the byline 2 columns and holds there", first == 2 && again == 2, "\(first ?? 0) then \(again ?? 0)")
                store.pointerUp(at: .page(pg, CGPoint(x: c.x + pull + 1, y: c.y)))
                check("  one undo step named Byline Width", undo.canUndo && undo.undoActionName == "Byline Width", undo.undoActionName)
                undo.undo()
                check("  undone", store.block(A)?.block.bylineColumns == 1)
            } else {
                check("IB-15 a byline grip to pull", false, "no grip")
            }
        }
        fresh()

        // rule 5 / IB-12: a drag onto another page previews and snaps there, and lands in one undo step
        do {
            let from = CGPoint(x: fA.minX + 60, y: fA.minY + 40)
            let to = CGPoint(x: g.x(1) + 60 + 4, y: 300 + 40 + 3)                   // 4,3 pt off a column and a line: it should snap
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 20, y: from.y)))
            store.pointerMoved(to: .page(pg2, to))
            check("IB-12 over the other page the story stays home and a preview shows there", frame(A) == fA && store.dropTarget == pg2 && store.dropPreview != nil
                  && store.activeGuides?.page == pg2 && store.block(A)?.page == pg, "target \(String(describing: store.dropTarget))")
            let preview = store.dropPreview
            check("  the preview is snapped against the target page's columns", preview.map { abs($0.minX - g.x(1)) < 0.01 } ?? false, preview.map(r) ?? "none")
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 20, y: from.y)))
            check("  back over its own page the preview goes", store.dropTarget == nil && store.dropPreview == nil)
            store.pointerMoved(to: .page(pg2, to))
            store.pointerUp(at: .page(pg2, to))
            let landed = store.block(A)
            check("  dropped: the story is on the other page where the preview was, its photo with it", landed?.page == pg2 && landed?.block.frame.rect == preview
                  && inset(P)?.page == pg2 && store.canvasSelection == .block(A), landed.map { "page \($0.page) \(r($0.block.frame.rect))" } ?? "gone")
            check("  one undo step", undo.canUndo && undo.undoActionName == "Move Story", undo.undoActionName)
            undo.undo()
            check("  undone: back on its page with its photo", store.block(A)?.page == pg && frame(A) == fA && inset(P)?.page == pg && !undo.canUndo)
        }
        fresh()

        // rule 5: dragging into the inspector takes the item off the page, one undo step
        do {
            let from = CGPoint(x: fP.midX, y: fP.midY)
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 30, y: from.y)))
            store.pointerMoved(to: .inspector)
            check("over the inspector the photo is shown back at its start", store.dragOutside && inset(P)?.inset.frame.rect == fP)
            store.pointerUp(at: .inspector)
            check("dropped on the inspector: the photo is off the page", inset(P) == nil && !store.dragOutside && store.dragging == nil)
            check("  one undo step", undo.canUndo, undo.undoActionName)
            undo.undo()
            check("  undone", inset(P)?.inset.frame.rect == fP)
        }
        fresh()

        // rule 5 / IB-14: the same modifiers everywhere
        do {
            store.canvasSelection = .block(A)
            let e = CGPoint(x: fA.maxX - 2, y: fA.minY + 40)
            drag(e, by: CGSize(width: 7, height: 0), on: pg, mods: [.command])
            check("IB-14 ⌘ while pulling an edge: no snapping, the edge goes exactly where the pointer went", frame(A)?.width == fA.width + 7, frame(A).map(r) ?? "")
            undo.undo()
            drag(e, by: CGSize(width: 7, height: 0), on: pg)
            check("  without ⌘ the edge snaps back to its column", frame(A)?.width == fA.width, frame(A).map(r) ?? "")
            undo.undo()
            drag(CGPoint(x: fA.minX + 60, y: fA.minY + 40), by: CGSize(width: 30, height: 5), on: pg, mods: [.shift, .command])
            check("  ⇧ holds a move to one axis", frame(A) == fA.offsetBy(dx: 30, dy: 0), frame(A).map(r) ?? "")
            undo.undo()
            store.canvasSelection = .block(A)
            drag(CGPoint(x: fA.maxX - 2, y: fA.maxY - 2), by: CGSize(width: 9, height: 20), on: pg, mods: [.shift, .command])
            check("  ⇧ holds a corner pull to one axis", frame(A) == CGRect(x: fA.minX, y: fA.minY, width: fA.width, height: fA.height + 20), frame(A).map(r) ?? "")
            undo.undo()
            // ⌘-drag inside a selected picture slides its crop
            let narrow = CGRect(x: fP.minX, y: fP.minY, width: fP.width, height: 60)
            store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: narrow) }
            undo.removeAllActions()
            store.canvasSelection = .inset(P)
            let hidden = store.hidden(in: store.issue.layout!.pages[pg].insets.first { $0.id == P }!)
            drag(CGPoint(x: narrow.midX, y: narrow.midY), by: CGSize(width: 0, height: 12), on: pg, mods: [.command])
            let f = inset(P)?.inset.focus
            check("  ⌘-drag inside the selected picture slides its crop and leaves the frame", hidden.height > 0.5 && f.map { abs($0.y - (0.5 - 12 / hidden.height)) < 0.001 } == true
                  && inset(P)?.inset.frame.rect == narrow, "focus \(String(describing: f)) hidden \(hidden)")
            check("  one undo step named Crop Photo", undo.canUndo && undo.undoActionName == "Crop Photo", undo.undoActionName)
            undo.undo()
            store.canvasSelection = nil
            drag(CGPoint(x: narrow.midX, y: narrow.midY), by: CGSize(width: 0, height: 12), on: pg, mods: [.command])
            check("  ⌘-drag on an unselected picture moves it", inset(P)?.inset.frame.rect == narrow.offsetBy(dx: 0, dy: 12) && store.canvasSelection == .inset(P))
            undo.undo()
            store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: fP) }
        }
        fresh()

        // rule 6 / IB-16: a lost mouse-up: the next press closes the old gesture, and recoverLostDrag does too
        do {
            let from = CGPoint(x: fA.minX + 60, y: fA.minY + 40)
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 50, y: from.y)), modifiers: [.command])
            let mid = frame(A)
            check("IB-16 mid-drag the story has moved", store.pointer.isDragging && mid == fA.offsetBy(dx: 50, dy: 0), mid.map(r) ?? "")
            // the mouse-up never arrives; the next press is on the photo
            store.pointerDown(at: CGPoint(x: fP.midX + 50, y: fP.midY), on: pg)
            check("  a new press closes the lost drag: the story stays where it was, with its own undo step",
                  frame(A) == mid && undo.canUndo && undo.undoActionName == "Move Story" && store.pointer.phase == .pressed && store.pointer.item == .inset(P) && store.dragging == nil,
                  "\(store.pointer.phase) \(undo.undoActionName)")
            store.pointerMoved(to: .page(pg, CGPoint(x: fP.midX + 50, y: fP.midY + 40)), modifiers: [.command])
            store.pointerUp(at: .page(pg, CGPoint(x: fP.midX + 50, y: fP.midY + 40)), modifiers: [.command])
            check("  the new drag moves the photo, not the old story", inset(P)?.inset.frame.rect == fP.offsetBy(dx: 50, dy: 40) && frame(A) == mid && undo.undoActionName == "Move Photo")
            undo.undo(); undo.undo()
            check("  two undo steps put both back", frame(A) == fA && inset(P)?.inset.frame.rect == fP && !undo.canUndo)
            // recoverLostDrag, as the composer calls it when the pointer is up
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 50, y: from.y)), modifiers: [.command])
            store.recoverLostDrag()
            check("  recoverLostDrag leaves the story where it was dropped and nothing mid-drag",
                  frame(A) == fA.offsetBy(dx: 50, dy: 0) && !store.pointer.isActive && store.dragging == nil && !store.editingNow && !store.resizing && store.activeGuides == nil && undo.canUndo)
            undo.undo()
            // lost while previewing on another page: it goes back home
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 50, y: from.y)))
            store.pointerMoved(to: .page(pg2, CGPoint(x: 300, y: 300)))
            store.pointerCancelled()
            check("  lost while over another page: the story is back where it started, no preview left",
                  frame(A) == fA && store.block(A)?.page == pg && store.dropTarget == nil && store.dropPreview == nil && !store.pointer.isActive)
            undo.removeAllActions()
        }
        fresh()

        // IB-3: undo after a resize keeps the selection
        do {
            store.canvasSelection = .block(A)
            drag(CGPoint(x: fA.midX, y: fA.maxY - 2), by: CGSize(width: 0, height: 40), on: pg, mods: [.command])
            check("a resize is one undo step named Resize Story", undo.canUndo && undo.undoActionName == "Resize Story" && frame(A)?.height == fA.height + 40, undo.undoActionName)
            undo.undo()
            check("IB-3 undo keeps the selection", store.canvasSelection == .block(A) && frame(A) == fA)
            undo.redo()
            check("  redo keeps it too", store.canvasSelection == .block(A) && frame(A)?.height == fA.height + 40)
            undo.undo()
            store.removeBlock(A == A ? B : A)
            undo.undo()
            check("  a removed item's selection is dropped, the rest kept", store.canvasSelection == .block(A) && frame(B) == fB)
        }
        fresh()

        // zoom: the reach is 8 screen points and the threshold 4, whatever the zoom
        do {
            store.canvasSelection = .block(A)
            store.zoom = 0.5
            let far = store.hit(at: CGPoint(x: fA.maxX + 14, y: fA.minY + 40), on: pg)
            check("zoomed out to 50% the edge reaches 16 page points", far.edge == .e, "\(String(describing: far.edge))")
            let from = CGPoint(x: fA.minX + 60, y: fA.minY + 40)
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 6, y: from.y)))
            let still = store.pointer.phase
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 10, y: from.y)))
            check("  6 page points (3 on screen) is a click, 10 (5 on screen) a drag", still == .pressed && store.pointer.phase == .dragging, "\(still) \(store.pointer.phase)")
            store.pointerCancelled(); undo.removeAllActions(); store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: fA) }; undo.removeAllActions()
            store.zoom = 2
            store.canvasSelection = .block(A)
            let near = store.hit(at: CGPoint(x: fA.maxX + 3, y: fA.minY + 40), on: pg)
            let past = store.hit(at: CGPoint(x: fA.maxX + 6, y: fA.minY + 40), on: pg)
            check("zoomed in to 200% the edge reaches 4 page points and no further", near.edge == .e && past.edge == nil, "\(String(describing: near.edge)) \(String(describing: past.edge))")
            store.pointerDown(at: from, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 1.5, y: from.y)))
            let c = store.pointer.phase
            store.pointerMoved(to: .page(pg, CGPoint(x: from.x + 2.5, y: from.y)))
            check("  1.5 page points (3 on screen) is a click, 2.5 (5 on screen) a drag", c == .pressed && store.pointer.phase == .dragging, "\(c) \(store.pointer.phase)")
            store.pointerCancelled(); undo.removeAllActions(); store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: fA) }; undo.removeAllActions()
            store.zoom = 1
        }
        fresh()

        // rule 2 / IB-4: an ad drawn smaller than its frame is hit where it's drawn
        do {
            let jpg = Bundle.main.resourceURL!.appendingPathComponent("SeedMedia/p2-engineers-rallying.jpg")
            if let ad = store.addExtra(.ad, file: jpg), let k = store.issue.extras.firstIndex(where: { $0.id == ad }) {
                store.issue.extras[k].columns = 3
                store.issue.extras[k].height = 150
                if let id = store.placeExtra(ad, on: pg2, at: CGPoint(x: 36, y: 900)), let i = inset(id), let s = shape(id, on: pg2) {
                    let f = i.inset.frame.rect
                    let strip = store.hit(at: CGPoint(x: f.minX + 20, y: f.minY + 75), on: pg2)
                    let middle = store.hit(at: CGPoint(x: f.midX, y: f.minY + 75), on: pg2)
                    check("IB-4 an ad's hit shape is its fitted picture, narrower than its frame", s.width < f.width - 100 && abs(s.midX - f.midX) < 0.5, "frame \(r(f)) shape \(r(s))")
                    check("  the white strip beside the picture is empty paper, the picture is the ad", !strip.isItem && middle.what == .inset(id), "\(strip.what) \(middle.what)")
                }
                store.removeExtra(ad)
            } else {
                check("IB-4 an ad to place", false, "")
            }
        }
        fresh()

        // right-click, hover and the drag start use the same answer: the hit test
        do {
            store.canvasSelection = .block(A)
            let p = CGPoint(x: fP.midX, y: fP.midY)
            let h = store.hit(at: p, on: pg)
            let hov = store.pointerHover(at: p, on: pg)
            store.pointerDown(at: p, on: pg)
            check("click, hover, cursor and press agree on what's under the pointer", h.what == .inset(P) && hov == h && store.pointer.hit == h)
            store.pointerUp(at: .page(pg, p))
            check("  and zone(at:) and itemUnder are the hit test", store.zone(at: CGPoint(x: fP.minX - 3, y: fP.midY), on: pg) == .w && store.itemUnder(p, on: pg)
                  && !store.itemUnder(CGPoint(x: 400, y: 1100), on: pg))
        }
        fresh()
        store.clearPage(pg); store.clearPage(pg2)
        undo.removeAllActions()
    }
}
