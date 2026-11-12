import AppKit

extension IssueStore {
    /// The window lost key mid-gesture, so the mouse-up won't come (rule 6): the pages' gesture closes, and so does
    /// one in the in-place editor (its own pointer), each as its `pointerCancelled` closes it. True when one was open.
    @discardableResult
    func lostMouse() -> Bool {
        var closed = false
        if let e = inPlace?.editor, e.pointer.isActive { e.pointerCancelled(); closed = true }
        if pointer.isActive { pointerCancelled(); closed = true }
        return closed
    }

    /// The pointer moved with no button down (a `mouseMoved`, which AppKit sends only then) while a gesture is
    /// still open: its mouse-up was lost without the window resigning key. The gesture closes as `pointerCancelled`
    /// closes it (the item stays where it was dropped, one undo step), and the move then hovers as usual, so the
    /// edge, outline and cursor come back to life (rule 6).
    @discardableResult
    func pointerHoverButtonUp(at p: CGPoint?, on page: Int) -> CanvasHit? {
        if pointer.isActive { pointerCancelled() }
        return pointerHover(at: p, on: page)
    }
}
