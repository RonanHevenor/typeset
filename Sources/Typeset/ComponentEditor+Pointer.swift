import AppKit

/// The pointer in the component editor: the pages' state machine (Store+Pointer.swift) for the editor's canvas,
/// idle → pressed → dragging / resizing / creating / marquee → idle, with the same rules. What's under the
/// pointer comes from `CanvasHitTest`, over the editor's items (`CanvasHitTest.editorItems`): the component at the
/// bottom, then its elements in the order they're drawn, each hit where it's drawn (a line along its length, an
/// ellipse inside its curve). A click selects what's under it (the component on its empty area) and a click off
/// the component clears; dragging an unselected element selects and moves it; the selected item's edges resize it;
/// ⇧ holds a drag to one axis, ⌘ turns snapping off; the threshold is the pages' (`IssueStore.dragThreshold`); one
/// undo step per gesture; a lost mouse-up leaves things where they were dropped and closes the gesture.
struct EditorPointerState: Equatable {
    enum Phase: Equatable { case idle, pressed, dragging, resizing, creating, marquee }
    var phase: Phase = .idle
    var down = CGPoint.zero
    var clickCount = 1
    /// What the hit test said was under the pointer when it went down.
    var hit: CanvasHit?
    /// The tool the press was made with: anything but Select draws a new element.
    var tool: EditorTool = .select
    /// The item's frame on the page when the gesture began; for the component, also the draft and where it sat.
    var start = CGRect.zero
    var startDraft: ComponentVersion?
    var startOrigin = CGPoint.zero
    /// The element as it was when the gesture began: a resize rebuilds it from this on every move, so passing
    /// through no width (a line's end pulled past its other end) loses nothing.
    var startElement: Element?
    var zone: ResizeZone?
    /// The element a drawing tool is making.
    var created: UUID?
    var marquee: CGRect?

    var item: EditorSelection? { hit.flatMap { ComponentEditor.selection(of: $0) } }
    var isActive: Bool { phase != .idle }
}

extension CanvasHitTest {
    /// The component editor's items, bottom first: the component (its frame), then each element where it's drawn.
    /// They take the pages' selections: the component is `.component(id)` and an element `.inset(id)`, so the one
    /// hit test, its edges and its rules serve both. Every element sits on the component: just outside a selected
    /// element's edge, over the component, the edge still has hold.
    static func editorItems(_ v: ComponentVersion, component: Component.ID, origin: CGPoint) -> [Item] {
        let frame = CGRect(origin: origin, size: v.size)
        var out = [Item(selection: .component(component), shape: frame, kind: nil)]
        for e in v.elements {
            let r = e.box.rect.offsetBy(dx: origin.x, dy: origin.y)
            var item = Item(selection: .inset(e.id), shape: r, kind: nil, hosts: [component])
            switch e {
            case .line(let l):
                item.form = .line(CGPoint(x: l.x1 + origin.x, y: l.y1 + origin.y), CGPoint(x: l.x2 + origin.x, y: l.y2 + origin.y), width: l.width)
            case .ellipse:
                item.form = .ellipse
            default:
                break
            }
            out.append(item)
        }
        return out
    }
}

extension ComponentEditor {
    static func selection(of hit: CanvasHit) -> EditorSelection? {
        switch hit.what {
        case .component: .component
        case .inset(let id): .element(id)
        case .block, .bylineGrip, .page: nil
        }
    }

    private var hitSelection: LayoutSelection? {
        switch selection {
        case .component: .component(component.id)
        case .element(let id): .inset(id)
        case nil: nil
        }
    }

    // MARK: hit testing

    func hitItems() -> [CanvasHitTest.Item] { CanvasHitTest.editorItems(draft, component: component.id, origin: origin) }

    /// What's under a point on the editor's page, with the selected item's resize edge if the point is on one.
    func hit(at p: CGPoint) -> CanvasHit {
        CanvasHitTest.hit(p, items: hitItems(), selected: hitSelection, zoom: zoom)
    }

    /// The pointer moving with no button down: what's under it, the edge of the selection it's over, and the
    /// cursor. Nothing is selected by hovering.
    @discardableResult
    func pointerHover(at p: CGPoint?) -> CanvasHit? {
        guard !pointer.isActive else { return nil }
        hover = p
        guard let p else {
            if hovered != nil { hovered = nil }
            if hoverEdge != nil { hoverEdge = nil }
            return nil
        }
        let h = hit(at: p)
        let item = Self.selection(of: h)
        if hovered != item { hovered = item }
        if hoverEdge != h.edge { hoverEdge = h.edge }
        return h
    }

    /// The cursor for a point: a drawing tool's crosshair, else what the hit test says.
    func cursor(at p: CGPoint) -> NSCursor {
        if tool != .select, drawsInsideOnly, !rect.contains(p) { return .arrow }    // in place: no drawing on the faded page
        return tool == .select ? hit(at: p).cursor : .crosshair
    }

    // MARK: the gesture

    func pointerDown(at p: CGPoint, modifiers: IssueStore.PointerModifiers = [], clickCount: Int = 1) {
        if pointer.isActive { pointerCancelled() }
        // in place, a drawing tool's press on the faded page round the component does nothing
        if tool != .select, drawsInsideOnly, !rect.contains(p) { return }
        var s = EditorPointerState(phase: .pressed, down: p, clickCount: clickCount, tool: tool)
        if tool == .select {
            let h = hit(at: p)
            s.hit = h
            switch Self.selection(of: h) {
            case .component:
                s.start = rect; s.startDraft = draft; s.startOrigin = origin
            case .element(let id):
                s.start = element(id).map(pageRect) ?? .zero
                s.startElement = element(id)
            case nil:
                break
            }
            if hoverEdge != h.edge { hoverEdge = h.edge }
        }
        pointer = s
    }

    func pointerMoved(to p: CGPoint, modifiers m: IssueStore.PointerModifiers = []) {
        guard pointer.isActive else { return }
        if pointer.phase == .pressed {
            guard hypot(p.x - pointer.down.x, p.y - pointer.down.y) * zoom >= IssueStore.dragThreshold else { return }
            begin()
        }
        snapOff = m.contains(.command)
        defer { snapOff = false }
        switch pointer.phase {
        case .dragging: drag(to: p, m)
        case .resizing: resize(to: p, m)
        case .creating: create(to: p, m)
        case .marquee: pointer.marquee = CGRect(origin: pointer.down, size: .zero).union(CGRect(origin: p, size: .zero))
        case .idle, .pressed: break
        }
    }

    func pointerUp(at p: CGPoint, modifiers m: IssueStore.PointerModifiers = []) {
        guard pointer.isActive else { return }
        pointerMoved(to: p, modifiers: m)
        let s = pointer
        switch s.phase {
        case .pressed:
            if s.tool != .select {
                // a click with a drawing tool puts down one of a standard size, its corner where the click was
                let size = Self.standardSize(s.tool, frame: frameType)
                snapOff = m.contains(.command)
                var r = snap(CGRect(origin: s.down, size: size), excluding: nil).rect
                snapOff = false
                if drawsInsideOnly { r = r.intersection(rect) }     // in place: kept inside the component
                if !r.isNull, r.width >= 1 || r.height >= 1, let e = makeElement(s.tool, in: r) { add(e, "Add \(s.tool.title)") }
                tool = .select
            } else {
                let sel = s.hit.flatMap(Self.selection(of:))
                if selection != sel { selection = sel }
            }
        case .dragging:
            endEdit(s.item == .component ? "Move Component" : "Move \(element(s.item?.elementID)?.kindTitle ?? "Element")")
        case .resizing:
            endEdit(s.item == .component ? "Resize Component" : "Resize \(element(s.item?.elementID)?.kindTitle ?? "Element")")
        case .creating:
            endEdit("Add \(s.tool.title)")
            tool = .select
        case .marquee, .idle:
            break
        }
        clearPointer()
    }

    /// The mouse-up never came (the window lost key, an alert came up): what was moved stays where it is, the
    /// gesture's undo step is closed, and nothing stays mid-drag. A drawing tool's new element is kept.
    func pointerCancelled() {
        let s = pointer
        switch s.phase {
        case .dragging: endEdit(s.item == .component ? "Move Component" : "Move")
        case .resizing: endEdit(s.item == .component ? "Resize Component" : "Resize")
        case .creating: endEdit("Add \(s.tool.title)"); tool = .select
        case .pressed, .marquee, .idle: if editingNow { endEdit("Edit") }
        }
        clearPointer()
    }

    /// A plain move arrived with a gesture still open: its mouse-up was lost while the window stayed key.
    @discardableResult
    func pointerHoverButtonUp(at p: CGPoint?) -> CanvasHit? {
        if pointer.isActive { pointerCancelled() }
        return pointerHover(at: p)
    }

    // MARK: how each gesture goes

    private func begin() {
        if pointer.tool != .select {
            pointer.phase = .creating
            beginEdit()
            let r = CGRect(origin: pointer.down, size: .zero)
            if let e = makeElement(pointer.tool, in: r) {
                draft.elements.append(e)
                pointer.created = e.id
                selection = .element(e.id)
            }
            return
        }
        guard let h = pointer.hit, let item = Self.selection(of: h) else {
            pointer.phase = .marquee                     // from empty page: a marquee (phase 7), never a pick-up
            pointer.marquee = CGRect(origin: pointer.down, size: .zero)
            return
        }
        if let z = h.edge {
            pointer.phase = .resizing
            pointer.zone = z
        } else {
            pointer.phase = .dragging
            if selection != item { selection = item }     // like Keynote: picked up as it's grabbed
        }
        beginEdit()
    }

    /// ⇧ holds a delta to its larger axis.
    private func constrained(_ dx: CGFloat, _ dy: CGFloat, _ m: IssueStore.PointerModifiers) -> (CGFloat, CGFloat) {
        guard m.contains(.shift) else { return (dx, dy) }
        return abs(dx) > abs(dy) ? (dx, 0) : (0, dy)
    }

    private func drag(to p: CGPoint, _ m: IssueStore.PointerModifiers) {
        let s = pointer
        let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
        let r = s.start.offsetBy(dx: dx, dy: dy)
        switch s.item {
        case .component:
            let (snapped, g) = snapComponent(r, edges: .all, move: true)
            guides = g
            origin = snapped.origin
        case .element(let id):
            let (snapped, g) = snap(r, excluding: id)
            guides = g
            setPageRect(id, snapped)
        case nil:
            break
        }
    }

    private func resize(to p: CGPoint, _ m: IssueStore.PointerModifiers) {
        let s = pointer
        guard let z = s.zone else { return }
        let (dx, dy) = constrained(p.x - s.down.x, p.y - s.down.y, m)
        switch s.item {
        case .component:
            let r = ResizeMath.resize(s.start, z, dx: dx, dy: dy, min: Self.minSize)
            let (snapped, g) = snapComponent(r, edges: z.edges, move: false, min: Self.minSize)
            guides = g
            if let d = s.startDraft { setComponentRect(snapped, elementsFrom: d, origin: s.startOrigin) }
        case .element(let id):
            guard element(id) != nil, var e = s.startElement else { return }
            let isLine: Bool = { if case .line = e { true } else { false } }()
            let minSize = isLine ? CGSize.zero : Self.minElementSize
            let r = ResizeMath.resize(s.start, z, dx: dx, dy: dy, min: minSize)
            let (snapped, g) = snap(r, excluding: id, edges: z.edges, move: false, min: minSize)
            guides = g
            e.box = Box(snapped.offsetBy(dx: -origin.x, dy: -origin.y))
            setElement(id) { $0 = e }
        case nil:
            break
        }
    }

    static let minElementSize = CGSize(width: 4, height: 4)

    /// Drawing a new element: from where the button went down to the pointer. ⇧ keeps a line level or upright.
    private func create(to p: CGPoint, _ m: IssueStore.PointerModifiers) {
        let s = pointer
        guard let id = s.created else { return }
        var q = p
        if drawsInsideOnly { q = CGPoint(x: q.x.clamped(rect.minX, rect.maxX), y: q.y.clamped(rect.minY, rect.maxY)) }
        var level = false, upright = false
        if s.tool == .line, m.contains(.shift) {
            if abs(p.x - s.down.x) > abs(p.y - s.down.y) { q.y = s.down.y; level = true } else { q.x = s.down.x; upright = true }
        }
        // the axis ⇧ holds isn't snapped: a level line stays level whatever lies a few points off it
        var edges: IssueStore.Edges = []
        if !upright { edges.insert(q.x >= s.down.x ? .right : .left) }
        if !level { edges.insert(q.y >= s.down.y ? .bottom : .top) }
        let raw = CGRect(x: min(s.down.x, q.x), y: min(s.down.y, q.y), width: abs(q.x - s.down.x), height: abs(q.y - s.down.y))
        var (r, g) = snap(raw, excluding: id, edges: edges, move: false)
        if drawsInsideOnly { let k = r.intersection(rect); r = k.isNull ? raw : k }
        guides = g
        if s.tool == .line {
            // a line runs from the press to the pointer, whichever way that is
            setElement(id) { e in
                guard case .line(var l) = e else { return }
                let a = CGPoint(x: s.down.x - origin.x, y: s.down.y - origin.y)
                let bx = (q.x >= s.down.x ? r.maxX : r.minX) - origin.x, by = (q.y >= s.down.y ? r.maxY : r.minY) - origin.y
                l.x1 = a.x; l.y1 = a.y; l.x2 = bx; l.y2 = by
                e = .line(l)
            }
        } else {
            setPageRect(id, r)
        }
    }

    private func clearPointer() {
        pointer = EditorPointerState()
        guides = []
        if let h = hover {
            let e = hit(at: h).edge
            if hoverEdge != e { hoverEdge = e }
        }
    }

    // MARK: snapping

    private func nearest(_ v: CGFloat, _ cands: [CGFloat], _ strong: [CGFloat]) -> CGFloat? {
        let threshold = (9 / zoom).clamped(4, 18)
        let weak = cands.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) < threshold ? $0 : nil }
        let hard = strong.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) < threshold * 2.5 ? $0 : nil }
        switch (weak, hard) {
        case (nil, nil): return nil
        case (let w?, nil): return w
        case (nil, let h?): return h
        case (let w?, let h?): return abs(w - v) <= abs(h - v) ? w : h
        }
    }

    private func snapped(_ r: CGRect, xs: [CGFloat], ys: [CGFloat], strongXs: [CGFloat], strongYs: [CGFloat],
                         edges: IssueStore.Edges, move: Bool, min minSize: CGSize = .zero) -> (rect: CGRect, guides: [Guide]) {
        if snapOff { return (r, []) }                                      // ⌘ held: nothing pulls
        var out = r
        var g: [Guide] = []
        if move {
            let dl = nearest(r.minX, xs, strongXs).map { $0 - r.minX }, dr = nearest(r.maxX, xs, strongXs).map { $0 - r.maxX }
            if let d = [dl, dr].compactMap({ $0 }).min(by: { abs($0) < abs($1) }) {
                out.origin.x += d; g.append(Guide(axis: .x, at: d == dl ? out.minX : out.maxX))
            }
            let dt = nearest(r.minY, ys, strongYs).map { $0 - r.minY }, db = nearest(r.maxY, ys, strongYs).map { $0 - r.maxY }
            if let d = [dt, db].compactMap({ $0 }).min(by: { abs($0) < abs($1) }) {
                out.origin.y += d; g.append(Guide(axis: .y, at: d == dt ? out.minY : out.maxY))
            }
        } else {
            // an edge snaps only where the item keeps at least its smallest size
            if edges.contains(.left), let x = nearest(r.minX, xs, strongXs), x < r.maxX, r.maxX - x >= minSize.width { out.origin.x = x; out.size.width = r.maxX - x; g.append(Guide(axis: .x, at: x)) }
            if edges.contains(.right), let x = nearest(r.maxX, xs, strongXs), x > out.minX, x - out.minX >= minSize.width { out.size.width = x - out.minX; g.append(Guide(axis: .x, at: x)) }
            if edges.contains(.top), let y = nearest(r.minY, ys, strongYs), y < r.maxY, r.maxY - y >= minSize.height { out.origin.y = y; out.size.height = r.maxY - y; g.append(Guide(axis: .y, at: y)) }
            if edges.contains(.bottom), let y = nearest(r.maxY, ys, strongYs), y > out.minY, y - out.minY >= minSize.height { out.size.height = y - out.minY; g.append(Guide(axis: .y, at: y)) }
        }
        return (out, g)
    }

    /// Pull an element's frame (page points) onto the component's own columns and edges, and the edges of its
    /// other elements; the component's edges and columns pull from further away.
    func snap(_ r: CGRect, excluding: UUID?, edges: IssueStore.Edges = .all, move: Bool = true, min minSize: CGSize = .zero) -> (rect: CGRect, guides: [Guide]) {
        let c = rect
        let cols = columnRects
        let strongXs = [c.minX, c.maxX] + cols.flatMap { [$0.minX, $0.maxX] }
        let strongYs = [c.minY, c.maxY]
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for e in draft.elements where e.id != excluding {
            let f = pageRect(e)
            xs += [f.minX, f.maxX, f.midX]; ys += [f.minY, f.maxY]
        }
        return snapped(r, xs: xs, ys: ys, strongXs: strongXs, strongYs: strongYs, edges: edges, move: move, min: minSize)
    }

    /// The page lines a component's own edges snap to: the full page, its margins, and the page's columns.
    var pageLines: (xs: [CGFloat], ys: [CGFloat]) {
        let g = Grid(columns: pageColumns)
        var xs: [CGFloat] = [0, HouseStyle.page.width, HouseStyle.margin, HouseStyle.margin + HouseStyle.liveWidth]
        for c in 0..<g.columns { xs += [g.x(c), g.x(c) + g.colWidth] }
        let ys: [CGFloat] = [0, HouseStyle.page.height, HouseStyle.margin, HouseStyle.insideTop, HouseStyle.bottom]
        return (xs, ys)
    }

    /// Pull the component's frame onto the page's margins, its columns and the full page.
    func snapComponent(_ r: CGRect, edges: IssueStore.Edges, move: Bool, min minSize: CGSize = .zero) -> (rect: CGRect, guides: [Guide]) {
        let (xs, ys) = pageLines
        return snapped(r, xs: [], ys: [], strongXs: xs, strongYs: ys, edges: edges, move: move, min: minSize)
    }
}
