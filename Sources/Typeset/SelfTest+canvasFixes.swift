import AppKit

/// Phase 2 review fixes: the byline grip yields to what's drawn over it, and a lost mouse-up with the window
/// still key is recovered on the next plain move.
extension SelfTest {
    /// Rule 3 / IB-11: the grip is the selected block's only where the block is topmost (pure hit test, no stage).
    static func canvasGripChecks(_ report: (String, Bool, String) -> Void) {
        let a = UUID(), b = UUID(), q = UUID()
        let fA = CGRect(x: 40, y: 100, width: 300, height: 400)
        let grip = CGRect(x: fA.maxX - 4.5, y: 150, width: 9, height: 22)          // half of it past A's frame
        let storyA = CanvasHitTest.Item(selection: .block(a), shape: fA, kind: nil, grip: grip)
        let inGrip = CGPoint(x: grip.midX - 2, y: grip.midY), outGrip = CGPoint(x: grip.midX + 2, y: grip.midY)
        let alone = CanvasHitTest.hit(outGrip, items: [storyA], selected: .block(a), zoom: 1)
        report("IB-11 with nothing over it the grip is hit on both sides of the frame", alone.what == .bylineGrip(a)
               && CanvasHitTest.hit(inGrip, items: [storyA], selected: .block(a), zoom: 1).what == .bylineGrip(a), "\(alone.what)")
        let quote = CanvasHitTest.Item(selection: .inset(q), shape: CGRect(x: fA.maxX - 60, y: 140, width: 120, height: 60),
                                       kind: .pullQuote, hosts: [a])
        let underQuote = CanvasHitTest.hit(inGrip, items: [storyA, quote], selected: .block(a), zoom: 1)
        report("  a pull quote over the grip is what's under the pointer (rule 3)", underQuote.what == .inset(q) && underQuote.cursor == .openHand,
               "\(underQuote.what)")
        let storyB = CanvasHitTest.Item(selection: .block(b), shape: CGRect(x: fA.maxX, y: 100, width: 300, height: 400), kind: nil)
        let later = CanvasHitTest.hit(outGrip, items: [storyA, storyB], selected: .block(a), zoom: 1)
        let inside = CanvasHitTest.hit(inGrip, items: [storyA, storyB], selected: .block(a), zoom: 1)
        report("  the half of the grip over a later story beside it is that story", later.what == .block(b), "\(later.what)")
        report("  the half inside the selected story's frame is still the grip", inside.what == .bylineGrip(a), "\(inside.what)")
        let earlier = CanvasHitTest.hit(outGrip, items: [storyB, storyA], selected: .block(a), zoom: 1)
        report("  and over an earlier neighbour outside the frame it reaches no further", earlier.what == .block(b), "\(earlier.what)")
    }

    /// IB-8, the zoom case: hover the selected item's edge, zoom with the mouse still; what's under the pointer is
    /// read again from where the mouse is, not from the page point it was over before the zoom.
    static func canvasZoomRehoverCheck(_ store: IssueStore, tag: String, z: CGFloat, selected: LayoutSelection, edgePoint: CGPoint,
                                       reset: () -> Void, build: (CGFloat) -> Void, view: () -> PageDropView, ui: () -> CanvasPointerUI,
                                       win: (CGPoint, PageDropView) -> CGPoint, local: (CGPoint, PageDropView) -> CGPoint,
                                       _ check: (String, Bool, String) -> Void) {
        reset(); build(z)
        store.canvasSelection = selected
        let mouse = win(edgePoint, view())                     // the still mouse, in window coordinates
        view().hover(at: local(edgePoint, view()))
        let before = store.hoverZone
        let saved = PageDropView.mouseNow
        defer { PageDropView.mouseNow = saved }
        PageDropView.mouseNow = { v in v.convert(mouse, from: nil) }
        let z2 = z < 2 ? z * 2 : z / 2
        build(z2)                                              // the pages laid out again at the new zoom
        ui().rehoverAtMouse()
        let moved = store.hover.map { hypot($0.point.x - edgePoint.x, $0.point.y - edgePoint.y) > 1 } ?? true
        check("IB-8 \(tag): after a zoom to \(Int(z2 * 100))% with the mouse still, the edge is worked out from where the mouse is",
              before == .e && moved && store.hoverZone != .e,
              "\(String(describing: before)) → \(String(describing: store.hoverZone)) at \(String(describing: store.hover?.point))")
        reset(); build(z)
    }

    /// Rule 6: a mouse-up lost with the window still key; the next plain move closes the gesture.
    static func canvasLostUpChecks(_ store: IssueStore, page pg: Int, photo P: Inset.ID, undo: UndoManager,
                                   _ report: (String, Bool, String) -> Void) {
        func frame() -> CGRect? { store.issue.layout?.pages[safe: pg]?.insets.first { $0.id == P }?.frame.rect }
        guard let start = frame() else { report("rule 6 a photo to drag", false, ""); return }
        undo.removeAllActions()
        let from = CGPoint(x: start.midX, y: start.midY)
        store.pointerDown(at: from, on: pg)
        store.pointerMoved(to: .page(pg, CGPoint(x: from.x - 20, y: from.y)))
        store.pointerMoved(to: .page(pg, CGPoint(x: from.x - 40, y: from.y)))
        let mid = store.pointer.phase
        let dropped = frame()
        let away = CGPoint(x: 5, y: 5)
        let h = store.pointerHoverButtonUp(at: away, on: pg)
        report("rule 6 a plain move after a lost mouse-up (window still key) closes the drag", mid == .dragging && !store.pointer.isActive
               && store.dragging == nil && !store.editingNow, "\(mid) -> \(store.pointer.phase)")
        report("  the photo stays where it was dropped, in one undo step", dropped != nil && frame() == dropped && dropped != start
               && undo.canUndo && undo.undoActionName == "Move Photo", undo.undoActionName)
        report("  and hover works again", h != nil && store.hover?.point == away, "")
        undo.undo()
        report("  undone", frame() == start, frame().map { "\($0)" } ?? "gone")
        undo.removeAllActions()
    }
}
