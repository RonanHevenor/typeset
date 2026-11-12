import AppKit

/// The pointer on the Pages canvas, as one state machine in the store (phase 2 of the components plan):
/// idle → pressed → dragging / resizing / cropping / bylineWidth / marquee → idle. The views feed it mouse down,
/// moves and up in page points and only draw what it says; a self-test can drive it the same way.
///
/// Rules it keeps: a click (down and up inside the drag threshold) selects what's under the pointer or clears
/// the selection on empty paper, and nothing else changes the selection; dragging an unselected item selects
/// and moves it; a drag from empty paper draws a marquee and never picks anything up; the selected item's
/// edges resize it; ⇧ holds to one axis, ⌘ turns snapping off, ⌥ crops a picture, ⌘-drag inside a selected
/// picture slides its crop; one undo step per gesture, opened only once the pointer has really moved; a lost
/// mouse-up (`pointerCancelled`, or a new press while a gesture is still open) leaves the item where it is and
/// closes the gesture cleanly.
extension IssueStore {
    /// Where the pointer is while a gesture runs: over a page (any page: a drag reports the page under the
    /// pointer, with the point in that page's coordinates, or the start page when it's over none), or well into
    /// the inspector, where a dropped item leaves the page.
    enum PointerLocation: Equatable {
        case page(Int, CGPoint)
        case inspector
    }

    struct PointerModifiers: OptionSet {
        let rawValue: Int
        static let shift = PointerModifiers(rawValue: 1), command = PointerModifiers(rawValue: 2), option = PointerModifiers(rawValue: 4)
        static var current: PointerModifiers {
            let f = NSEvent.modifierFlags
            var m: PointerModifiers = []
            if f.contains(.shift) { m.insert(.shift) }
            if f.contains(.command) { m.insert(.command) }
            if f.contains(.option) { m.insert(.option) }
            return m
        }
    }

    struct PointerState: Equatable {
        enum Phase: Equatable { case idle, pressed, dragging, resizing, cropping, bylineWidth, marquee, pullingFill }
        var phase: Phase = .idle
        var page = 0
        var down = CGPoint.zero
        var clickCount = 1
        /// What was under the pointer when it went down, from the hit test at that moment.
        var hit: CanvasHit?
        /// The item's frame when the gesture began, and its pictures' (for a block, which carries them).
        var start = CGRect.zero
        var insetStarts: [Inset.ID: CGRect] = [:]
        var cropStart = CGPoint.zero
        var zone: ResizeZone?
        var fitHeight: CGFloat?
        var startWidth: CGFloat = 0
        /// The rect swept from empty paper, for multi-select (phase 7).
        var marquee: CGRect?
        /// A press on a placed component: the frame under the pointer, for ⌘-drag (slide its picture) and ⌥-drag
        /// (pull its content out). A plain click or drag still takes the component whole.
        var frame: FrameTarget?
        /// ⇧ was down at the press: a click adds the item to the selection or takes it out (phase 7).
        var shift = false
        /// A drag of several selected items: where each one (and each picture in a selected block) started.
        var group: [LayoutSelection: CGRect] = [:]

        var item: LayoutSelection? { hit?.selection }
        var isActive: Bool { phase != .idle }
        var isDragging: Bool { phase == .dragging }
    }

    /// How far the pointer moves before a press becomes a drag, in screen points: the one threshold everywhere.
    static let dragThreshold: CGFloat = 4

    // MARK: hit testing

    /// Everything on a page in draw order, bottom first.
    func hitItems(on page: Int) -> [CanvasHitTest.Item] {
        guard let pl = issue.layout?.pages[safe: page] else { return [] }
        return CanvasHitTest.items(pl, composed: displayPages[safe: page], zoom: zoom) { [self] in picture(for: $0)?.size }
    }

    /// What's under a point on a page, with the selected item's resize edge if the point is on one.
    func hit(at p: CGPoint, on page: Int) -> CanvasHit {
        CanvasHitTest.hit(p, items: hitItems(on: page), selected: canvasSelection, zoom: zoom)
    }

    /// The pointer moving with no button down: remembers where it is and which edge of the selected item it's
    /// over, and says what the cursor should show. Nothing is selected by hovering.
    @discardableResult
    func pointerHover(at p: CGPoint?, on page: Int) -> CanvasHit? {
        guard !pointer.isActive else { return nil }
        guard inPlace == nil else { return nil }                // the page under an in-place editor isn't live
        guard let p else {
            if hover?.page == page { hover = nil; if hoverZone != nil { hoverZone = nil } }
            return nil
        }
        hover = (page, p)
        let h = hit(at: p, on: page)
        if h.edge != hoverZone { hoverZone = h.edge }
        return h
    }

    /// Work the hovered edge out again from the current geometry: after a nudge, a zoom, an undo or a resize, the
    /// pointer may be still while what's under it has moved.
    func refreshHover() {
        guard !pointer.isActive, let h = hover else { return }
        let z = hit(at: h.point, on: h.page).edge
        if z != hoverZone { hoverZone = z }
    }

    /// Drop the selection when the item it names has left the layout (after an undo, a removal); keep it otherwise.
    func pruneSelection() {
        // an in-place editor whose component has left the layout (an undo past its start) closes, keeping nothing
        if let ip = inPlace, placedComponent(ip.placed) == nil { closeInPlace() }
        pruneSelectionSet()
        guard let sel = canvasSelection else { return }
        let pages = issue.layout?.pages ?? []
        let exists = switch sel {
        case .block(let id): pages.contains { $0.stories.contains { $0.id == id } }
        case .inset(let id): pages.contains { $0.insets.contains { $0.id == id } }
        case .component(let id): pages.contains { $0.components.contains { $0.id == id } }
        }
        if !exists { canvasSelection = nil }
    }

    // MARK: the gesture

    /// The button goes down at `p` on `page`. A gesture still open from a lost mouse-up is closed first.
    func pointerDown(at p: CGPoint, on page: Int, modifiers: PointerModifiers = [], clickCount: Int = 1) {
        if pointer.isActive { pointerCancelled() }
        guard inPlace == nil else { return }                    // while a component is edited in place, the pages take no clicks
        let h = hit(at: p, on: page)
        var s = PointerState(phase: .pressed, page: page, down: p, clickCount: clickCount, hit: h)
        s.shift = modifiers.contains(.shift)
        switch h.what {
        case .block(let id), .bylineGrip(let id):
            if let (_, b) = block(id) {
                s.start = b.frame.rect
                s.insetStarts = Dictionary(uniqueKeysWithValues: insets(with: b, on: page).map { ($0.id, $0.frame.rect) })
                if let by = displayPages[safe: page]?.blockResults[id]?.byline { s.startWidth = by.width }
            }
        case .inset(let id):
            if let inset = inset(id, on: page) {
                // an ad's frame becomes the ad itself (fitted, without empty sides) once it's moved or resized
                s.start = inset.kind == .extra ? (composer.geometry(inset, nil, extra(inset.extra))?.picture ?? inset.frame.rect) : inset.frame.rect
                s.cropStart = inset.focus
            }
        case .component(let id):
            if let (_, c) = placedComponent(id) {
                s.start = c.frame.rect
                if h.edge == nil, let t = frameTarget(at: p, on: page), t.placed == id {
                    s.frame = t
                    s.cropStart = fill(of: t)?.focus ?? CGPoint(x: 0.5, y: 0.5)
                }
            }
        case .page:
            break
        }
        pointer = s
        if h.edge != hoverZone { hoverZone = h.edge }
    }

    /// The pointer moves with the button down. Until it has gone `dragThreshold` screen points from where it went
    /// down nothing happens; then the gesture starts, by what was pressed.
    func pointerMoved(to location: PointerLocation, modifiers: PointerModifiers = []) {
        guard pointer.isActive else { return }
        if pointer.phase == .pressed {
            guard case .page(let page, let p) = location else { return }
            let d = page == pointer.page ? hypot(p.x - pointer.down.x, p.y - pointer.down.y) * zoom : .infinity
            guard d >= Self.dragThreshold else { return }
            begin(modifiers)
        }
        switch pointer.phase {
        case .dragging: drag(to: location, modifiers)
        case .resizing: if case .page(_, let p) = location { resize(to: p, modifiers) }
        case .cropping: if case .page(_, let p) = location { crop(to: p, modifiers) }
        case .bylineWidth: if case .page(_, let p) = location { bylineWidth(to: p) }
        case .marquee: if case .page(_, let p) = location { pointer.marquee = CGRect(origin: pointer.down, size: .zero).union(CGRect(origin: p, size: .zero)) }
        case .pullingFill: pullFill(to: location)
        case .idle, .pressed: break
        }
    }

    /// The button comes up. A press that never became a drag is a click: it selects or clears.
    func pointerUp(at location: PointerLocation, modifiers: PointerModifiers = []) {
        guard pointer.isActive else { return }
        pointerMoved(to: location, modifiers: modifiers)
        let s = pointer
        switch s.phase {
        case .pressed:
            if s.shift, let sel = s.hit?.selection {
                toggleSelection(sel, on: s.page)                // ⇧-click: in or out of the selection
            } else if s.shift {
                break                                           // ⇧-click on empty paper keeps the selection
            } else if let sel = s.hit?.selection {
                if canvasSelection != sel || isMultiSelection { canvasSelection = sel }
                focusedPage = s.page
                if s.clickCount == 2, case .block(let id) = sel { fitBlock(id) }
                if s.clickCount == 2, case .component(let id) = sel { enterInPlace(id) }
            } else if s.hit?.onPage == true {
                if !selectionSet.isEmpty { select([]) }
                focusedPage = s.page
            }
        case .dragging:
            finishDrag(s)
        case .resizing:
            endEdit(Self.gestureName("Resize", s.item))
            resizing = false
        case .cropping:
            endEdit("Crop Photo")
        case .bylineWidth:
            endEdit("Byline Width")
        case .pullingFill:
            finishPull(s, at: location)
        case .marquee:
            finishMarquee(s.marquee ?? .null, on: s.page, adding: s.shift)
        case .idle:
            break
        }
        clearPointer()
    }

    /// The undo name for a gesture on an item: "Move Story", "Resize Photo", "Move Component".
    static func gestureName(_ verb: String, _ item: LayoutSelection?) -> String {
        switch item {
        case .block: "\(verb) Story"
        case .inset: "\(verb) Photo"
        case .component: "\(verb) Component"
        case nil: verb
        }
    }

    /// The mouse-up never arrived (the drag left the window, an alert came up, the app lost key). Whatever was
    /// being moved stays where it is on its page, the gesture's undo step is closed, and nothing stays mid-drag.
    func pointerCancelled() {
        let s = pointer
        switch s.phase {
        case .dragging:
            if !s.group.isEmpty {
                if dragOutside || dropTarget != nil { applyGroup(s.group, page: s.page, dx: 0, dy: 0) }
                endEdit("Move Items")
            } else if dragOutside || dropTarget != nil {       // it was shown off its page: it's still at its start there
                apply(s.start, s)
            }
            endEdit(Self.gestureName("Move", s.item))
        case .resizing:
            endEdit(Self.gestureName("Resize", s.item))
        case .cropping: endEdit("Crop Photo")
        case .bylineWidth: endEdit("Byline Width")
        case .pullingFill:
            // nothing changed while the content was carried: it stays in its frame
            break
        case .pressed, .marquee, .idle:
            if editingNow { endEdit("Edit") } else { activeGuides = nil; fitBand = nil }
        }
        clearPointer()
    }

    // MARK: how each gesture goes

    private func begin(_ m: PointerModifiers) {
        guard let h = pointer.hit else { pointer.phase = .marquee; return }
        if isMultiSelection, h.edge == nil, let sel = h.selection, selectionSet.contains(sel), selectionPage == pointer.page {
            // an item of a multiple selection: the whole set moves
            pointer.phase = .dragging
            pointer.group = groupStarts(on: pointer.page)
            beginEdit()
            focusedPage = pointer.page
            dragging = sel
            dragOutside = false
            return
        }
        switch h.what {
        case .page:
            pointer.phase = .marquee
            pointer.marquee = CGRect(origin: pointer.down, size: .zero)
        case .bylineGrip:
            pointer.phase = .bylineWidth
            beginEdit()
        case .block(let id):
            if let z = h.edge { startResize(z, block: id) } else { startDrag(h) }
        case .inset(let id):
            guard let inset = inset(id, on: pointer.page) else { pointer.phase = .marquee; return }
            if let z = h.edge {
                startResize(z, block: nil)
            } else if canvasSelection == .inset(id) && inset.kind != .pullQuote && m.contains(.command) {
                // ⌘-drag inside a selected picture slides the picture in its frame
                pointer.phase = .cropping
                if canvasSelection != .inset(id) { canvasSelection = .inset(id) }
                focusedPage = pointer.page
                beginEdit()
            } else {
                startDrag(h)
            }
        case .component(let id):
            if let z = h.edge {
                startResize(z, block: nil)
            } else if canvasSelection == .component(id), let t = pointer.frame, m.contains(.command), t.frame.type == .image, picture(in: t) != nil {
                // ⌘-drag inside a selected component's image frame slides its picture, as in a photo
                pointer.phase = .cropping
                focusedPage = pointer.page
                beginEdit()
            } else if canvasSelection == .component(id), let t = pointer.frame, m.contains(.option), fill(of: t) != nil {
                // ⌥-drag on a filled frame of the selected component pulls its content out
                pointer.phase = .pullingFill
                focusedPage = pointer.page
            } else {
                startDrag(h)
            }
        }
    }

    private func startDrag(_ h: CanvasHit) {
        pointer.phase = .dragging
        beginEdit()
        if let sel = h.selection, canvasSelection != sel { canvasSelection = sel }     // like Keynote: it's picked up as it's grabbed
        focusedPage = pointer.page
        dragging = h.selection
        dragOutside = false
    }

    private func startResize(_ z: ResizeZone, block id: StoryBlock.ID?) {
        pointer.phase = .resizing
        pointer.zone = z
        if let id, z.vertical, let (_, b) = block(id), let a = article(b.article) {
            // pulling top or bottom: show where the edge lands for a comfortable fit, snap at house style
            let h = fitHeights(b, on: pointer.page, article: a)
            let f = b.frame.rect
            let band = z.edges.contains(.bottom)
                ? CGRect(x: f.minX, y: f.minY + h.tight, width: f.width, height: h.loose - h.tight)
                : CGRect(x: f.minX, y: f.maxY - h.loose, width: f.width, height: h.loose - h.tight)
            fitBand = (pointer.page, band, z.edges.contains(.bottom) ? f.minY + h.house : f.maxY - h.house)
            pointer.fitHeight = h.house
        }
        beginEdit()
        resizing = true
    }

    /// ⇧ holds a delta to its larger axis.
    private func constrained(_ dx: CGFloat, _ dy: CGFloat, _ m: PointerModifiers) -> (CGFloat, CGFloat) {
        guard m.contains(.shift) else { return (dx, dy) }
        return abs(dx) > abs(dy) ? (dx, 0) : (0, dy)
    }

    private func drag(to location: PointerLocation, _ m: PointerModifiers) {
        let s = pointer
        if !s.group.isEmpty { dragGroup(to: location, m); return }
        guard let item = s.item else { return }
        switch location {
        case .inspector:
            // over the inspector the item is off its page: shown back at its start until it's dropped there
            if !dragOutside { dragOutside = true }
            apply(s.start, s)
            dropTarget = nil; dropPreview = nil; activeGuides = nil
        case .page(let target, let p):
            if dragOutside { dragOutside = false }
            let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
            let r = s.start.offsetBy(dx: dx, dy: dy)
            let excluding: Set<UUID>
            let outline: CGFloat
            switch item {
            case .block(let id): excluding = Set([id] + s.insetStarts.keys); outline = 0
            case .inset(let id): excluding = [id]; outline = inset(id, on: s.page).map { self.outline(of: $0) } ?? 0
            case .component(let id): excluding = [id]; outline = 0
            }
            snapOff = m.contains(.command)
            let (snapped, guides) = snap(r, page: target, excluding: excluding, outline: outline)
            snapOff = false
            if target == s.page {
                dropTarget = nil; dropPreview = nil
                activeGuides = (target, guides)
                apply(snapped, s)
            } else {
                // onto another page: it's shown there as a dashed preview, snapped against that page, and stays
                // on its own page until it's dropped
                apply(s.start, s)
                dropTarget = target
                dropPreview = onPage(snapped)
                activeGuides = (target, guides)
            }
        }
    }

    private func finishDrag(_ s: PointerState) {
        if !s.group.isEmpty { finishGroupDrag(s); return }
        guard let item = s.item else { clearPointer(); return }
        let name = Self.gestureName("Move", item)
        if dragOutside {
            apply(s.start, s)
            endEdit(name)
            dropOutside(item)
            return
        }
        if let target = dropTarget, let frame = dropPreview, target != s.page {
            apply(s.start, s)
            switch item {
            case .block(let id): moveBlock(id, from: s.page, to: target, frame: frame)
            case .inset(let id): moveInset(id, from: s.page, to: target, frame: frame)
            case .component(let id): moveComponent(id, from: s.page, to: target, frame: frame)
            }
            endEdit(name)
            return
        }
        if let f = currentFrame(item, on: s.page) { apply(onPage(f), s) }
        endEdit(name)
    }

    private func resize(to p: CGPoint, _ m: PointerModifiers) {
        let s = pointer
        guard let z = s.zone, let item = s.item else { return }
        let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
        snapOff = m.contains(.command)
        defer { snapOff = false }
        switch item {
        case .block(let id):
            let (rect, guides) = resizedBlock(id, start: s.start, zone: z, dx: dx, dy: dy, page: s.page, fitHeight: s.fitHeight)
            activeGuides = (s.page, guides)
            setBlockFrame(id, page: s.page, frame: rect)
        case .inset(let id):
            guard let inset = inset(id, on: s.page) else { return }
            let (rect, guides) = resizedInset(inset, start: s.start, zone: z, dx: dx, dy: dy, free: m.contains(.option), page: s.page)
            activeGuides = (s.page, guides)
            setInsetFrame(id, page: s.page, frame: rect)
        case .component(let id):
            let (rect, guides) = resizedComponent(id, start: s.start, zone: z, dx: dx, dy: dy, page: s.page)
            activeGuides = (s.page, guides)
            setComponentFrame(id, page: s.page, frame: rect)
        }
    }

    private func crop(to p: CGPoint, _ m: PointerModifiers) {
        let s = pointer
        if case .component = s.item, let t = s.frame {
            let hidden = hidden(in: t)
            let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
            var f = s.cropStart
            if hidden.width > 0.5 { f.x = s.cropStart.x - dx / hidden.width }
            if hidden.height > 0.5 { f.y = s.cropStart.y - dy / hidden.height }
            setFillFocus(t, focus: f)
            return
        }
        guard case .inset(let id) = s.item, let inset = inset(id, on: s.page) else { return }
        // dragging the picture to the right shows more of its left: the focus moves the other way
        let hidden = hidden(in: inset)
        let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
        var f = s.cropStart
        if hidden.width > 0.5 { f.x = s.cropStart.x - dx / hidden.width }
        if hidden.height > 0.5 { f.y = s.cropStart.y - dy / hidden.height }
        setInsetFocus(id, page: s.page, focus: f)
    }

    /// The byline grows from the width it had when the grip was taken: columns = round(start + pull).
    private func bylineWidth(to p: CGPoint) {
        let s = pointer
        guard case .block(let id) = s.item, let (page, b) = block(id),
              let k = issue.layout?.pages[safe: page]?.stories.firstIndex(where: { $0.id == id }) else { return }
        let w = s.startWidth + (p.x - s.down.x)
        let n = (1...max(1, b.columns)).min { abs(grid.span($0) - w) < abs(grid.span($1) - w) } ?? 1
        if n != b.bylineColumns { issue.layout!.pages[page].stories[k].bylineColumns = n }
    }

    // MARK: several items at once (phase 7)

    /// The set follows the pointer as one: its bounding box snaps as a single frame would (⌘ off, ⇧ to one axis);
    /// onto another page it shows there as one dashed outline and stays put until it's dropped.
    private func dragGroup(to location: PointerLocation, _ m: PointerModifiers) {
        let s = pointer
        let bounds = groupBounds(s.group)
        guard !bounds.isNull else { return }
        switch location {
        case .inspector:
            if !dragOutside { dragOutside = true }
            applyGroup(s.group, page: s.page, dx: 0, dy: 0)
            dropTarget = nil; dropPreview = nil; activeGuides = nil
        case .page(let target, let p):
            if dragOutside { dragOutside = false }
            let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
            snapOff = m.contains(.command)
            let (snapped, guides) = snap(bounds.offsetBy(dx: dx, dy: dy), page: target, excluding: Set(s.group.keys.map(\.itemID)))
            snapOff = false
            let placed = onPage(snapped)
            if target == s.page {
                dropTarget = nil; dropPreview = nil
                activeGuides = (target, guides)
                applyGroup(s.group, page: s.page, dx: placed.minX - bounds.minX, dy: placed.minY - bounds.minY)
            } else {
                applyGroup(s.group, page: s.page, dx: 0, dy: 0)
                dropTarget = target
                dropPreview = placed
                activeGuides = (target, guides)
            }
        }
    }

    /// Lets go of the set: where it was dragged on its page, onto another page, or into the inspector (stories on
    /// hold, the rest off the page). One undo step, whichever it is.
    private func finishGroupDrag(_ s: PointerState) {
        let bounds = groupBounds(s.group)
        if dragOutside {
            applyGroup(s.group, page: s.page, dx: 0, dy: 0)
            dropSetOutside(selectionSet)
            endEdit("Move Items")
            select([])
            return
        }
        if let target = dropTarget, let frame = dropPreview, target != s.page {
            applyGroup(s.group, page: s.page, dx: 0, dy: 0)
            moveSet(s.group, from: s.page, to: target, dx: frame.minX - bounds.minX, dy: frame.minY - bounds.minY)
            endEdit("Move Items")
            return
        }
        endEdit("Move Items")
    }

    // MARK: helpers

    private func inset(_ id: Inset.ID, on page: Int) -> Inset? {
        issue.layout?.pages[safe: page]?.insets.first { $0.id == id }
    }

    private func currentFrame(_ item: LayoutSelection, on page: Int) -> CGRect? {
        switch item {
        case .block(let id): issue.layout?.pages[safe: page]?.stories.first { $0.id == id }?.frame.rect
        case .inset(let id): inset(id, on: page)?.frame.rect
        case .component(let id): issue.layout?.pages[safe: page]?.components.first { $0.id == id }?.frame.rect
        }
    }

    /// Put the dragged item at `r` on its own page; a block's pictures keep their place in it.
    private func apply(_ r: CGRect, _ s: PointerState) {
        switch s.item {
        case .block(let id):
            let dx = r.minX - s.start.minX, dy = r.minY - s.start.minY
            for (iid, f) in s.insetStarts { setInsetFrame(iid, page: s.page, frame: f.offsetBy(dx: dx, dy: dy)) }
            setBlockFrame(id, page: s.page, frame: r)
        case .inset(let id):
            setInsetFrame(id, page: s.page, frame: r)
        case .component(let id):
            setComponentFrame(id, page: s.page, frame: r)
        case nil:
            break
        }
    }

    /// Carrying a frame's content: over another frame that takes it, that frame is previewed; off the component,
    /// letting go clears the frame it came from (see finishPull).
    private func pullFill(to location: PointerLocation) {
        guard let t = pointer.frame, let fill = fill(of: t), let item = dragItem(for: fill, in: t.frame) else { return }
        switch location {
        case .inspector:
            if !dragOutside { dragOutside = true }
            dropTarget = nil; dropPreview = nil
        case .page(let page, let p):
            if dragOutside { dragOutside = false }
            if let target = frameTarget(at: p, on: page, for: item), target.frame.id != t.frame.id || target.placed != t.placed {
                dropTarget = page; dropPreview = target.rect
            } else {
                dropTarget = nil; dropPreview = nil
            }
        }
    }

    /// Lets go of a frame's content: onto another frame that takes it, it moves there; over a frame that doesn't
    /// take it, or anywhere on its own component, nothing changes; anywhere else (off the component, onto the page,
    /// into the sidebar) the frame is cleared and what it held goes back to the sidebar. One undo step.
    private func finishPull(_ s: PointerState, at location: PointerLocation) {
        guard let t = s.frame, let fill = fill(of: t), let item = dragItem(for: fill, in: t.frame) else { return }
        var target: FrameTarget?
        if case .page(let page, let p) = location {
            if let under = frameTarget(at: p, on: page) {
                guard accepts(under.frame, item) else { return }          // a near miss never loses what it carries
                target = under
            } else if case .component(t.placed)? = hitItems(on: page).last(where: { $0.shape.contains(p) })?.selection {
                return                                                    // still on its own component
            }
        }
        if let target, target.frame.id == t.frame.id, target.placed == t.placed { return }      // dropped where it was
        let moved = target.flatMap { tg in makeFill(item, for: tg).map { (tg, $0) } }
        edit(moved == nil ? "Clear Frame" : "Move to Frame") {
            setFill(nil, of: t)
            if let (target, f) = moved { setFill(f, of: target) }
        }
    }

    private func clearPointer() {
        pointer = PointerState()
        dragging = nil
        dragOutside = false
        dropTarget = nil
        dropPreview = nil
        resizing = false
        fitBand = nil
        activeGuides = nil
        refreshHover()
    }
}
