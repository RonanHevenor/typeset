import AppKit

/// What the pointer is over on a page: the one answer the canvas uses for clicks, hover, the cursor, drag starts,
/// resize edges and right-click (phase 2, rule 3).
struct CanvasHit: Equatable {
    enum What: Equatable {
        case block(StoryBlock.ID)
        case inset(Inset.ID)
        /// A placed component, taken whole: a click anywhere on its frame selects it, not the frame under the point.
        case component(PlacedComponent.ID)
        /// The grip on the selected block's byline (only when it has 2+ columns).
        case bylineGrip(StoryBlock.ID)
        /// Empty paper (`onPage`), or nothing at all beside the page.
        case page
    }
    var what: What
    /// The drawn shape of what's hit; the page's rect for `.page`.
    var shape: CGRect
    /// The resize edge of the selected item under the point, if the point is on one of its edges where it's topmost.
    var edge: ResizeZone?
    var onPage = true

    var selection: LayoutSelection? {
        switch what {
        case .block(let id), .bylineGrip(let id): .block(id)
        case .inset(let id): .inset(id)
        case .component(let id): .component(id)
        case .page: nil
        }
    }
    var isItem: Bool { if case .page = what { false } else { true } }

    var cursor: NSCursor {
        if let edge { return edge.cursor }
        switch what {
        case .bylineGrip: return .resizeLeftRight
        case .block, .inset, .component: return .openHand
        case .page: return .arrow
        }
    }
}

/// A pure hit test over one page: what is where, in draw order, with hit areas that match what's drawn (rule 2).
enum CanvasHitTest {
    /// How far either side of an edge the pointer can be and still have hold of it, in screen points; a corner
    /// reaches a little further so it's easy to catch.
    static let reach: CGFloat = 8
    static let corner: CGFloat = 12
    /// How far either side of a thin line the pointer can be and still be on it, in screen points.
    static let lineReach: CGFloat = 4

    /// The distance from a point to the segment a–b.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        let t = len > 0 ? (((p.x - a.x) * dx + (p.y - a.y) * dy) / len).clamped(0, 1) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// One thing drawn on the page. `items` lists them bottom first, so a later item is on top of an earlier one.
    struct Item: Equatable {
        var selection: LayoutSelection
        /// What's drawn: a block's frame; a photo's picture plus caption; a pull quote's box; an ad's fitted
        /// picture plus caption.
        var shape: CGRect
        var kind: Inset.Kind?                      // nil for a story block or a component
        /// What this item sits on: for a picture or quote, the stories and components under it; for a component,
        /// the stories under it. They aren't neighbours to its edge band (a click 3 pt outside still has hold of
        /// its edge).
        var hosts: Set<UUID> = []
        /// The byline grip's rect, in page points, for a block of 2+ columns.
        var grip: CGRect?
        /// What the pointer has to be over to hit it: the shape's rect (everything on the pages), or, for the
        /// component editor's shapes (phase 6), the ellipse in it or the line itself.
        var form: Form = .rect

        enum Form: Equatable {
            case rect, ellipse
            /// A line from one end to the other, `width` thick: it's held `lineReach` screen points either side.
            case line(CGPoint, CGPoint, width: CGFloat)
        }

        /// Whether the point is on what's drawn.
        func holds(_ p: CGPoint, zoom: CGFloat) -> Bool {
            switch form {
            case .rect:
                return shape.contains(p)
            case .ellipse:
                guard shape.width > 0, shape.height > 0 else { return false }
                let x = (p.x - shape.midX) / (shape.width / 2), y = (p.y - shape.midY) / (shape.height / 2)
                return x * x + y * y <= 1
            case .line(let a, let b, let w):
                return CanvasHitTest.distance(p, a, b) <= max(w / 2, CanvasHitTest.lineReach / zoom)
            }
        }

        var id: UUID { switch selection { case .block(let id): id; case .inset(let id): id; case .component(let id): id } }
        var isBlock: Bool { if case .block = selection { true } else { false } }
        var isComponent: Bool { if case .component = selection { true } else { false } }
        /// Which edges can be pulled: only the sides of a pull quote.
        func zone(_ z: ResizeZone?) -> ResizeZone? {
            if case .line(let a, let b, _) = form {
                // a line's ends: a level rule lengthens from its left or right end, an upright one from its top
                // or bottom; a slanting one from its corners
                if abs(a.y - b.y) < 0.01 { return z?.widthOnly }
                if abs(a.x - b.x) < 0.01 { return z?.heightOnly }
                return z.flatMap { [.nw, .ne, .se, .sw].contains($0) ? $0 : nil }
            }
            switch kind {
            case .pullQuote: return z?.widthOnly
            default: return z
            }
        }
    }

    /// The items of a page in draw order: stories as laid out (a later one over an earlier one), then placed
    /// components (stories wrap around them, so where a story's frame and a component overlap, what's drawn is the
    /// component), then pictures and quotes, which sit over the stories they're in.
    static func items(_ page: PageLayout, composed: ComposedPage?, zoom: CGFloat, imageSize: (Inset) -> CGSize?) -> [Item] {
        var out: [Item] = []
        for b in page.stories {
            var grip: CGRect?
            if b.columns > 1, let by = composed?.blockResults[b.id]?.byline {
                let w = 9 / zoom, h = 22 / zoom
                grip = CGRect(x: by.maxX - w / 2, y: by.midY - h / 2, width: w, height: h)
            }
            out.append(Item(selection: .block(b.id), shape: b.frame.rect, kind: nil, grip: grip))
        }
        for c in page.components {
            // a component is its frame (phase 5); while it's being edited, each element (phase 6)
            let shape = composed?.componentFrames[c.id] ?? c.frame.rect
            guard shape.width > 0, shape.height > 0 else { continue }
            let hosts = Set(page.stories.filter { $0.frame.rect.insetBy(dx: -1, dy: -1).intersects(shape) }.map(\.id))
            out.append(Item(selection: .component(c.id), shape: shape, kind: nil, hosts: hosts))
        }
        for inset in page.insets {
            var shape = composed?.insetFrames[inset.id] ?? inset.frame.rect
            if inset.kind == .extra, let s = imageSize(inset), s.width > 0, s.height > 0 {
                // an ad or graphic is drawn fitted inside its frame: the hit area is the picture, not the frame
                let r = composed?.pictureFrames[inset.id] ?? inset.frame.rect
                let k = min(r.width / s.width, r.height / s.height)
                let fitted = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
                let caption = CGRect(x: shape.minX, y: r.maxY, width: shape.width, height: max(0, shape.maxY - r.maxY))
                shape = caption.height > 0 ? fitted.union(caption) : fitted
            }
            let under = out.filter { $0.isBlock || $0.isComponent }
            let hosts = Set(under.filter { $0.shape.insetBy(dx: -1, dy: -1).intersects(shape) }.map(\.id))
            out.append(Item(selection: .inset(inset.id), shape: shape, kind: inset.kind, hosts: hosts))
        }
        return out
    }

    /// What's under `p` (page points). The topmost item whose shape holds the point wins. The selected item's
    /// resize edges are `reach` screen points either side of its edge, but only where the selected item is itself
    /// topmost (or nothing is, or only a story it sits on): over anything drawn above it, the edge yields. Where
    /// the edge is live, the hit is the selected item, with the edge.
    static func hit(_ p: CGPoint, items: [Item], selected: LayoutSelection?, zoom: CGFloat) -> CanvasHit {
        let page = CGRect(origin: .zero, size: HouseStyle.page)
        let top = items.last { $0.holds(p, zoom: zoom) }
        var hit = top.map { CanvasHit(what: what($0), shape: $0.shape) } ?? CanvasHit(what: .page, shape: page)
        hit.onPage = page.contains(p)
        guard let selected, let k = items.firstIndex(where: { $0.selection == selected }) else { return hit }
        let item = items[k]
        // the grip and the edge yield to whatever is drawn over the selected item at this point (a picture on a
        // selected story, a story laid out later), and outside its frame to any neighbour; a story a
        // picture or component sits on is neither
        if let top, top != item {
            let above = items.firstIndex(of: top)! > k
            let host = item.hosts.contains(top.id)
            if above || !host { return hit }
        }
        if let g = item.grip, g.contains(p) {
            // the grip belongs to the selected block: it sits on the byline's edge, where the block is topmost
            hit = CanvasHit(what: .bylineGrip(item.id), shape: g, onPage: hit.onPage)
            return hit
        }
        guard let z = item.zone(ResizeZone.at(p, in: item.shape, reach: reach / zoom, corner: corner / zoom)) else { return hit }
        // the band is part of the selected item's hit area: a press there goes to it, whatever is drawn beneath
        hit.what = what(item)
        hit.shape = item.shape
        hit.edge = z
        return hit
    }

    private static func what(_ item: Item) -> CanvasHit.What {
        switch item.selection {
        case .block(let id): .block(id)
        case .inset(let id): .inset(id)
        case .component(let id): .component(id)
        }
    }
}
