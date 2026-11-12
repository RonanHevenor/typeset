import AppKit

/// Phase 2, the view side: the page's AppKit pointer view driven with real mouse events, two pages stacked in a
/// container as on the canvas, at 50%, 100% and 200%. These check what the store-side tests can't: that the view
/// turns window points into the right page points on the right page, that it takes presses in the edge band past
/// the page (IB-10), that hover, cursor, click and the right-click target agree, that a drag finds the page under
/// it and the inspector past a page wider than the canvas (IB-13), that a click doesn't scroll (IB-2), that the
/// view holds no drag state of its own (IB-16), and that a drop from the inspector honours ⌘ (IB-14).
extension SelfTest {
    @MainActor
    static func canvasViewChecks(_ store: IssueStore, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3,
              let a0 = store.issue.articles.first(where: { !$0.photos.isEmpty && $0.body.count > 5 }),
              let a1 = store.issue.articles.first(where: { $0.id != a0.id && !$0.photos.isEmpty && $0.body.count > 5 }),
              let a2 = store.issue.articles.first(where: { $0.id != a0.id && $0.id != a1.id && $0.body.count > 5 }) else {
            check("canvas views: a generated issue with three stories to test on", false, "none"); return
        }
        let pg = layout.pages.count - 1, pg2 = layout.pages.count - 2
        let saved = (zoom: store.zoom, undo: store.undoManager, inspector: store.showInspector, focus: store.focusedPage)
        defer { store.zoom = saved.zoom; store.undoManager = saved.undo; store.showInspector = saved.inspector; store.focusedPage = saved.focus }
        store.zoom = 1
        let g = store.grid
        let undo = UndoManager()

        // the stage: on the last page story A (2 columns) with its photo P flush right, story B below; story C on
        // the page above it
        store.clearPage(pg); store.clearPage(pg2)
        store.undoManager = undo
        guard let A = store.addBlock(a0.id, on: pg, at: CGPoint(x: 40, y: 100)),
              let B = store.addBlock(a1.id, on: pg, at: CGPoint(x: 40, y: 700)),
              let C = store.addBlock(a2.id, on: pg2, at: CGPoint(x: 40, y: 100)) else { check("canvas views: blocks placed", false, ""); return }
        let fA = CGRect(x: g.x(0), y: 100, width: g.span(2), height: 500)
        let fB = CGRect(x: g.x(0), y: 700, width: g.span(2), height: 300)
        let fC = CGRect(x: g.x(0), y: 100, width: g.span(2), height: 400)
        store.edit("Stage") { store.setBlockFrame(A, page: pg, frame: fA); store.setBlockFrame(B, page: pg, frame: fB); store.setBlockFrame(C, page: pg2, frame: fC) }
        guard let P = store.placePhoto(a0.photos[0].id, of: a0.id, on: pg, in: A) else { check("canvas views: photo placed", false, ""); return }
        let fP = CGRect(x: fA.maxX - g.span(1), y: 250, width: g.span(1), height: 150)
        store.edit("Stage") { store.setInsetFrame(P, page: pg, frame: fP) }
        _ = store.displayPages
        let stage = store.issue.layout

        func frame(_ id: StoryBlock.ID) -> CGRect? { store.block(id)?.block.frame.rect }
        func insetFrame(_ id: Inset.ID) -> CGRect? { store.issue.layout?.pages[safe: pg]?.insets.first { $0.id == id }?.frame.rect }
        func reset() {
            store.pointerCancelled()
            store.issue.layout = stage
            _ = store.displayPages
            undo.removeAllActions()
            store.canvasSelection = nil
            store.hover = nil; store.hoverZone = nil
        }

        // two page views stacked as on the canvas: page pg2 on top, pg below, in a y-up container (window coordinates)
        let pad = CanvasHitTest.reach
        var ui = CanvasPointerUI()
        var top = PageDropView(frame: .zero), bottom = PageDropView(frame: .zero)
        var container = NSView(frame: .zero)
        func build(_ z: CGFloat) {
            store.zoom = z
            ui = CanvasPointerUI()
            let w = HouseStyle.page.width * z + 2 * pad, h = HouseStyle.page.height * z + 2 * pad
            container = NSView(frame: CGRect(x: 0, y: 0, width: w + 400, height: 2 * h + 200))
            top = PageDropView(frame: CGRect(x: 40, y: 100 + h + 34, width: w, height: h))
            bottom = PageDropView(frame: CGRect(x: 40, y: 100, width: w, height: h))
            for (v, i) in [(top, pg2), (bottom, pg)] {
                v.store = store; v.index = i; v.pad = pad; v.ui = ui
                ui.views[i] = .init(view: v)
                container.addSubview(v)
            }
            ui.canvasMaxX = container.frame.width - 400 + 40      // the canvas ends a little past the pages
        }
        /// A page point on a view, in the container's (window) coordinates.
        func win(_ q: CGPoint, _ v: PageDropView) -> CGPoint {
            v.convert(CGPoint(x: pad + q.x * store.zoom, y: pad + q.y * store.zoom), to: nil)
        }
        func local(_ q: CGPoint, _ v: PageDropView) -> CGPoint { CGPoint(x: pad + q.x * store.zoom, y: pad + q.y * store.zoom) }
        func event(_ type: NSEvent.EventType, _ w: CGPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func click(_ q: CGPoint, _ v: PageDropView, clicks: Int = 1) {
            v.mouseDown(with: event(.leftMouseDown, win(q, v), clicks: clicks))
            v.mouseUp(with: event(.leftMouseUp, win(q, v), clicks: clicks))
        }
        /// Press on `v` at `q`, move in two steps to window point `to`, and let go.
        func drag(_ q: CGPoint, _ v: PageDropView, to: CGPoint, _ mods: NSEvent.ModifierFlags = [], during: () -> Void = {}) {
            let from = win(q, v)
            v.mouseDown(with: event(.leftMouseDown, from, mods))
            v.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), mods))
            v.mouseDragged(with: event(.leftMouseDragged, to, mods))
            during()
            v.mouseUp(with: event(.leftMouseUp, to, mods))
        }

        for z: CGFloat in [0.5, 1, 2] {
            let tag = "at \(Int(z * 100))%"
            reset(); build(z)

            // rule 1/2/3: hover, cursor, click and the right-click target are one answer, on both pages
            let inP = CGPoint(x: fP.midX, y: fP.midY), inA = CGPoint(x: fA.minX + 30, y: fA.minY + 60)
            let empty = CGPoint(x: fA.maxX + 120, y: 160), inC = CGPoint(x: fC.midX, y: fC.midY)
            var agree = true, detail = ""
            for (q, v, want) in [(inP, bottom, LayoutSelection?.some(.inset(P))), (inA, bottom, .block(A)), (empty, bottom, nil), (inC, top, .block(C))] {
                let h = v.hover(at: local(q, v))
                let hovered = ui.hovered?.item
                let menu = ui.hovered.flatMap { $0.page == v.index ? $0.item : nil }     // what PageMenuArea hands the menu
                let cursorOK = (want == nil ? h?.cursor === NSCursor.arrow : h?.cursor === NSCursor.openHand)
                click(q, v)
                let selected = store.canvasSelection
                if hovered != want || menu != want || selected != want || !cursorOK || store.pointer.isActive {
                    agree = false; detail += "\(q): hover \(String(describing: hovered)) select \(String(describing: selected)); "
                }
            }
            check("canvas views \(tag): hover, cursor, click and right-click target agree on both pages (rules 1-3)", agree, detail)
            check("  nothing was moved or put on the undo stack by those clicks", !undo.canUndo && store.issue.layout == stage, undo.undoActionName)

            // IB-2: a click on a page makes it the focused page without scrolling to it; a menu's change still scrolls
            store.focusedPage = pg
            click(inC, top)
            check("IB-2 \(tag): a click on another page focuses it but doesn't scroll", store.focusedPage == pg2 && !ui.shouldScroll(to: pg2),
                  "focused \(String(describing: store.focusedPage))")
            store.focusedPage = 0
            check("  a change from elsewhere (a menu, the navigator) scrolls", ui.shouldScroll(to: 0))

            // the drag threshold is in screen points: 3 screen points at any zoom is still a click
            store.canvasSelection = nil
            let wB = win(CGPoint(x: fB.minX + 40, y: fB.minY + 80), bottom)
            bottom.mouseDown(with: event(.leftMouseDown, wB))
            bottom.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: wB.x + 3, y: wB.y)))
            bottom.mouseUp(with: event(.leftMouseUp, CGPoint(x: wB.x + 3, y: wB.y)))
            check("IB-1 \(tag): a 3-screen-point wobble through the view only selects", store.canvasSelection == .block(B) && frame(B) == fB && !undo.canUndo)

            // IB-10: an item flush with the page's left edge can be taken by its edge from just outside the page
            reset(); build(z)
            let flush = CGRect(x: 0, y: 250, width: fP.width, height: fP.height)
            store.setInsetFrame(P, page: pg, frame: flush)
            _ = store.displayPages
            undo.removeAllActions()
            store.canvasSelection = .inset(P)
            let outside = CGPoint(x: -5 / z, y: flush.midY)
            let takes = bottom.takesPress(at: local(outside, bottom))
            let h = bottom.hover(at: local(outside, bottom))
            check("IB-10 \(tag): 5 screen points outside the page, the selected photo's left edge is live", takes && h?.edge == .w && store.hoverZone == .w,
                  "takes \(takes) edge \(String(describing: h?.edge))")
            store.canvasSelection = nil
            check("  with nothing selected the band past the page takes no press", !bottom.takesPress(at: local(outside, bottom)))
            store.canvasSelection = .inset(P)
            let from = win(outside, bottom)
            drag(outside, bottom, to: CGPoint(x: from.x + 40, y: from.y))
            let after = insetFrame(P) ?? .zero
            check("  pulling it from there resizes the photo from its left edge", after.minX > 1 && after.width < flush.width && store.canvasSelection == .inset(P),
                  "\(after)")
            check("  one undo step named Resize Photo", undo.canUndo && undo.undoActionName == "Resize Photo", undo.undoActionName)

            // IB-11: the byline grip shows left-right on every move, and doesn't reach past the story
            reset(); build(z)
            store.setBylineColumns(1, block: A)
            _ = store.displayPages
            store.canvasSelection = .block(A)
            if let grip = store.hitItems(on: pg).first(where: { $0.selection == .block(A) })?.grip {
                let h1 = bottom.hover(at: local(CGPoint(x: grip.midX, y: grip.midY), bottom))
                let h2 = bottom.hover(at: local(CGPoint(x: grip.midX + 1 / z, y: grip.midY + 2 / z), bottom))
                let h3 = bottom.hover(at: local(CGPoint(x: grip.midX + 10 / z, y: grip.midY), bottom))
                check("IB-11 \(tag): over the byline grip the cursor stays left-right", h1?.what == .bylineGrip(A) && h1?.cursor === NSCursor.resizeLeftRight
                      && h2?.cursor === NSCursor.resizeLeftRight)
                check("  10 screen points right of it is the story again, not the grip", h3?.what == .block(A), "\(String(describing: h3?.what))")
            } else {
                check("IB-11 \(tag): the 2-column story has a byline grip", false)
            }

            // IB-8: a nudge with the pointer still: the hovered edge and item are worked out again
            reset(); build(z)
            store.canvasSelection = .block(B)
            let nearEdge = CGPoint(x: fB.maxX + 3 / z, y: fB.midY)
            bottom.hover(at: local(nearEdge, bottom))
            let before = store.hoverZone
            store.nudge(dx: 20 / z, dy: 0)                  // 20 screen points: past the 8-point edge band at any zoom
            ui.refresh(store)
            check("IB-8 \(tag): after a nudge the view's hover follows the story", before == .e && store.hoverZone == nil && ui.hovered?.item == .block(B),
                  "\(String(describing: before)) → \(String(describing: store.hoverZone))")
            canvasZoomRehoverCheck(store, tag: tag, z: z, selected: .block(B), edgePoint: CGPoint(x: fB.maxX - 3 / z, y: fB.midY),
                                   reset: reset, build: build, view: { bottom }, ui: { ui }, win: win, local: local, check)

            // rule 5, IB-12: a drag from one page view onto the other previews there, lands there, one undo step
            reset(); build(z)
            let target = win(CGPoint(x: 400, y: 300), bottom)
            var previewed = false
            drag(CGPoint(x: fC.minX + 30, y: fC.minY + 60), top, to: target) {
                previewed = store.dropTarget == pg && store.dropPreview != nil && store.pointer.isDragging && store.block(C)?.page == pg2
            }
            check("IB-12 \(tag): a story dragged from one page view to the other is previewed there, staying home until the drop", previewed)
            check("  it lands on the page under the pointer", store.block(C)?.page == pg && !store.pointer.isActive && store.dropTarget == nil,
                  "page \(String(describing: store.block(C)?.page))")
            check("  one undo step", undo.canUndo && undo.undoActionName == "Move Story", undo.undoActionName)
            undo.undo()
            check("  undone: back on its own page", store.block(C)?.page == pg2 && frame(C) == fC && !undo.canUndo)
            // the same drop in one jump: a mouse-up with no drag event before it is routed as a drag too
            reset(); build(z)
            top.mouseDown(with: event(.leftMouseDown, win(CGPoint(x: fC.minX + 30, y: fC.minY + 60), top)))
            top.mouseUp(with: event(.leftMouseUp, target))
            check("  a press and release in one jump onto the other page drops there too", store.block(C)?.page == pg && !store.pointer.isActive
                  && undo.undoActionName == "Move Story", "page \(String(describing: store.block(C)?.page))")

            // IB-16: a drag whose mouse-up never comes leaves no state behind; the next drag is its own
            reset(); build(z)
            let wB2 = win(CGPoint(x: fB.minX + 40, y: fB.minY + 80), bottom)
            bottom.mouseDown(with: event(.leftMouseDown, wB2))
            bottom.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: wB2.x + 60, y: wB2.y - 30)))
            let moved = frame(B)
            bottom.lostMouse()                              // the window lost key mid-drag
            check("IB-16 \(tag): a lost mouse-up closes the drag; the story stays where it was dropped", !store.pointer.isActive && store.dragging == nil
                  && frame(B) == moved && moved != fB && undo.canUndo, "\(String(describing: moved))")
            let steps = undo.canUndo
            let wA = win(CGPoint(x: fA.minX + 30, y: fA.minY + 60), bottom)
            drag(CGPoint(x: fA.minX + 30, y: fA.minY + 60), bottom, to: CGPoint(x: wA.x + 50 * z, y: wA.y))
            check("  the next drag moves the story pressed, not the lost one", frame(B) == moved && frame(A) != fA && store.canvasSelection == .block(A))
            undo.undo()
            check("  with its own undo step", steps && frame(A) == fA && frame(B) == moved)
        }

        // IB-13: past the edge of a page wider than the canvas, the drag is over the inspector
        do {
            let wide = PointerRouting.PageArea(index: 3, frame: CGRect(x: 40, y: 0, width: 1600, height: 2400), visible: CGRect(x: 40, y: 0, width: 960, height: 2400))
            let below = PointerRouting.PageArea(index: 4, frame: CGRect(x: 40, y: -2500, width: 1600, height: 2400), visible: CGRect(x: 40, y: -800, width: 960, height: 700))
            let over = PointerRouting.location(CGPoint(x: 1100, y: 500), pages: [wide, below], canvasMaxX: 1000, inspector: true, start: 3, zoom: 2)
            let noInspector = PointerRouting.location(CGPoint(x: 1100, y: 500), pages: [wide, below], canvasMaxX: 1000, inspector: false, start: 3, zoom: 2)
            let onPage = PointerRouting.location(CGPoint(x: 900, y: 500), pages: [wide, below], canvasMaxX: 1000, inspector: true, start: 3, zoom: 2)
            let onOther = PointerRouting.location(CGPoint(x: 500, y: -200), pages: [wide, below], canvasMaxX: 1000, inspector: true, start: 3, zoom: 2)
            check("IB-13 a drag past the canvas's edge, over a page scrolled out under the inspector, is over the inspector", over == .inspector)
            check("  with the inspector closed it stays on its page", noInspector == .page(3, CGPoint(x: 530, y: 950)), "\(noInspector)")
            check("  on the visible part of a page, it's that page, in its points", onPage == .page(3, CGPoint(x: 430, y: 950)), "\(onPage)")
            check("  and on the visible part of the next page, that one", onOther == .page(4, CGPoint(x: 230, y: 50)), "\(onOther)")

            // through the views: carry the photo well past the canvas and let go: it comes off the page
            reset(); build(1)
            store.showInspector = true
            let wP = win(CGPoint(x: fP.midX, y: fP.midY), bottom)
            var outside = false
            drag(CGPoint(x: fP.midX, y: fP.midY), bottom, to: CGPoint(x: (ui.canvasMaxX ?? 0) + 60, y: wP.y)) { outside = store.dragOutside }
            check("  through the page view: dragged past the canvas the photo is over the inspector, and dropped there it leaves the page",
                  outside && insetFrame(P) == nil && !store.pointer.isActive)
        }

        // IB-14: ⌘ while dragging in from the inspector turns snapping off for the preview, and leaves no switch on
        reset(); build(1)
        let off = CGPoint(x: 333.3, y: 703.7)
        bottom.preview(.story(a2.id), at: off, modifiers: [.command])
        let free = store.dropPreview
        let freeGuides = store.activeGuides?.guides.count ?? 0
        bottom.preview(.story(a2.id), at: off, modifiers: [])
        check("IB-14 an inspector drop previewed with ⌘ has no guides and leaves snapping on afterwards",
              free != nil && freeGuides == 0 && !store.snapOff && store.dropTarget == pg, "\(String(describing: free))")
        check("  without ⌘ the preview is still there", store.dropPreview != nil)
        store.dropTarget = nil; store.dropPreview = nil; store.activeGuides = nil

        reset()
        store.clearPage(pg); store.clearPage(pg2)
        undo.removeAllActions()
    }
}
