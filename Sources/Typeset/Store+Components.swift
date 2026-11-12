import AppKit

// Components on the page (phase 5): the sidebar's catalogue, placing a component from it, moving, resizing and
// removing one, filling its frames by dropping stories, photos and ads on them, clearing them, sliding a picture
// in an image frame, and switching a placed component to another version. The pointer side is in
// Store+Pointer.swift; this is what it calls.

extension IssueStore {
    // MARK: the catalogue

    /// Every component the sidebar offers: the shipped Header and Folio, the library's component files, and any
    /// the open issue carries that neither has ("in this issue only"). One entry per component, with every
    /// version any of them knows.
    func componentCatalog() -> [Component] {
        var out: [Component] = []
        func merge(_ c: Component) {
            if let i = out.firstIndex(where: { $0.id == c.id }) {
                for v in c.versions where !out[i].versions.contains(where: { $0.number == v.number }) { out[i].versions.append(v) }
            } else {
                out.append(c)
            }
        }
        BuiltInComponents.all.forEach(merge)
        Self.libraryComponents().forEach(merge)
        issue.componentVersions.forEach(merge)
        return out.map { c in var c = c; c.versions.sort { $0.number < $1.number }; return c }
    }

    /// The library's component files (`ComponentFiles.libraryFiles`, which the self-tests point at a library of
    /// their own; they never read the user's).
    static func libraryComponents() -> [Component] { ComponentFiles.libraryFiles().map(\.component) }

    func catalogComponent(_ id: Component.ID) -> Component? { componentCatalog().first { $0.id == id } }

    /// Where a component runs in this issue, for its sidebar row: "Page 1 · v3", "Page 2 · custom".
    func componentRuns(_ id: Component.ID) -> [String] {
        var out: [String] = []
        for (i, p) in (issue.layout?.pages ?? []).enumerated() {
            for c in p.components where c.component == id {
                let s = "Page \(i + 1) · " + (c.custom != nil ? "custom" : "v\(c.version)")
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }

    /// What a placed component's selection box says: "Header v3", or "Header custom" once it's edited in place.
    func componentLabel(_ p: PlacedComponent) -> String {
        let name = issue.componentName(p.component) ?? "Component"
        return p.custom != nil ? "\(name) custom" : "\(name) v\(p.version)"
    }

    func placedComponent(_ id: PlacedComponent.ID) -> (page: Int, placed: PlacedComponent)? {
        for (i, p) in (issue.layout?.pages ?? []).enumerated() {
            if let c = p.components.first(where: { $0.id == id }) { return (i, c) }
        }
        return nil
    }

    func resolvedComponent(_ id: PlacedComponent.ID) -> ResolvedComponent? {
        placedComponent(id).flatMap { ResolvedComponent($0.placed, in: issue, pageColumns: issue.layout?.columns ?? grid.columns) }
    }

    /// The body and whole-story frames of a page's components that hold a story, as the composer sets them.
    func componentBlocks(on page: Int) -> [Composer.ComponentBlock] {
        guard let l = issue.layout, let p = l.pages[safe: page] else { return [] }
        let articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return composer.componentBlocks(on: p, issue: issue, pageColumns: l.columns, articles: articles)
    }

    // MARK: placing, moving, resizing, removing

    /// Where a component dragged in from the sidebar would land with its top-left corner at `point`, snapped to
    /// the margins, columns and what's on the page, and kept on the page.
    func componentFrame(_ id: Component.ID, version n: Int, on page: Int, at point: CGPoint?) -> CGRect? {
        guard let v = catalogComponent(id)?.version(n), issue.layout?.pages.indices.contains(page) == true else { return nil }
        let at = point ?? CGPoint(x: HouseStyle.margin, y: (issue.layout!.pages[page].isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop))
        let r = onPage(CGRect(x: at.x, y: at.y, width: v.width, height: v.height))
        return onPage(snap(r, page: page).rect)
    }

    /// Puts a version of a component on a page, copying that version into the issue so the file stands alone.
    @discardableResult
    func placeComponent(_ id: Component.ID, version n: Int, on page: Int, at point: CGPoint? = nil) -> PlacedComponent.ID? {
        guard let c = catalogComponent(id), c.version(n) != nil, let r = componentFrame(id, version: n, on: page, at: point) else { return nil }
        var placed: PlacedComponent.ID?
        edit("Place Component") { placed = issue.place(c, version: n, on: page, at: r.origin) }
        if let placed { canvasSelection = .component(placed); focusedPage = page }
        return placed
    }

    func setComponentFrame(_ id: PlacedComponent.ID, page: Int, frame: CGRect) {
        guard let k = issue.layout?.pages[safe: page]?.components.firstIndex(where: { $0.id == id }) else { return }
        issue.layout!.pages[page].components[k].frame = Box(frame)
        if !editingNow { scheduleSave() }
    }

    /// Moves a placed component to another page, with its fills. It goes on top of what that page has.
    func moveComponent(_ id: PlacedComponent.ID, from: Int, to: Int, frame: CGRect) {
        guard var layout = issue.layout, layout.pages.indices.contains(to),
              let k = layout.pages[safe: from]?.components.firstIndex(where: { $0.id == id }) else { return }
        var c = layout.pages[from].components.remove(at: k)
        c.frame = Box(frame)
        layout.pages[to].components.append(c)
        issue.layout = layout
        focusedPage = to
        if !editingNow { scheduleSave() }
    }

    /// Takes a placed component off its page. A story that ran only in its frames goes back on hold.
    func removeComponent(_ id: PlacedComponent.ID) {
        edit("Remove Component") {
            // the issue keeps its copy of the version: undo puts the component back, and undo restores the layout only
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].components.removeAll { $0.id == id } }
        }
        if canvasSelection == .component(id) { canvasSelection = nil }
    }

    /// A component's frame with the pulled edges moved, snapped to the margins, the page's columns and what's on
    /// the page. The boxes, lines and shapes inside stretch with it; the type keeps its size (decision 6).
    func resizedComponent(_ id: PlacedComponent.ID, start: CGRect, zone: ResizeZone, dx: CGFloat, dy: CGFloat, page: Int) -> (rect: CGRect, guides: [Guide]) {
        let r = ResizeMath.resize(start, zone, dx: dx, dy: dy, min: CGSize(width: 24, height: 12))
        let (snapped, guides) = snap(r, page: page, excluding: [id], edges: zone.edges, move: false)
        let page = CGRect(origin: .zero, size: HouseStyle.page)
        let i = snapped.intersection(page)
        return (i.isNull || i.width < 24 || i.height < 12 ? snapped : i, guides)
    }

    // MARK: filling frames

    /// A frame on a placed component, where it sits on its page.
    struct FrameTarget: Equatable {
        var placed: PlacedComponent.ID
        var page: Int
        var frame: Frame
        var rect: CGRect
    }

    /// The frame under a point: on the topmost component there (nothing drawn over it at that point), the topmost
    /// of its frames whose box holds the point. A box holds its top and left edges, not its bottom and right, so a
    /// point exactly on the line between two frames belongs to one of them: the one right of or below it. With an
    /// item, only a frame that takes that item.
    func frameTarget(at p: CGPoint, on page: Int, for item: DragItem? = nil) -> FrameTarget? {
        guard case .component(let id)? = hitItems(on: page).last(where: { $0.shape.contains(p) })?.selection,
              let rc = resolvedComponent(id) else { return nil }
        for f in rc.version.frames.reversed() where !f.type.isIssueField {
            let r = rc.rect(f.box)
            guard r.contains(p) else { continue }
            if let item, !accepts(f, item) { return nil }      // the frame under the point is the answer, taken or not
            return FrameTarget(placed: id, page: page, frame: f, rect: r)
        }
        return nil
    }

    /// Whether a frame takes a dragged item: a story fills any story frame (the frame shows the field its type
    /// asks for); a photo fills an image frame; a pull quote a pull-quote frame; an ad or graphic an ad frame or
    /// an unlinked image frame. An unlinked image frame takes a story only if the story has a photo. A linked
    /// image frame shows its group's story, so it takes no ad: dropped there, an ad would empty the whole group.
    func accepts(_ f: Frame, _ item: DragItem) -> Bool {
        switch item {
        case .story(let a):
            guard f.type.isStoryField else { return false }
            if f.type == .image, f.link == nil { return article(a)?.photos.isEmpty == false }
            return true
        case .photo: return f.type == .image
        case .quote: return f.type == .pullQuote
        case .extra: return f.type == .ad || (f.type == .image && f.link == nil)
        case .component: return false
        }
    }

    /// Drops an item on a frame. A linked frame's whole group takes it (every frame with the letter shows its own
    /// field of the story); an unlinked frame takes it alone. Replaces what was there.
    func fillFrame(_ item: DragItem, _ t: FrameTarget) {
        guard let fill = makeFill(item, for: t) else { return }
        edit("Fill Frame") { setFill(fill, of: t) }
    }

    /// What a frame keeps for a dropped item, keyed by its link letter or by the frame itself.
    func makeFill(_ item: DragItem, for t: FrameTarget) -> Fill? {
        guard accepts(t.frame, item) else { return nil }
        var fill: Fill
        switch item {
        case .story(let a): fill = Fill(article: a, photo: t.frame.type == .image ? article(a)?.photos.first?.id : nil)
        case .photo(let a, let p): fill = Fill(article: a, photo: p)
        case .quote(let a): fill = Fill(article: a)
        case .extra(let e): fill = Fill(extra: e)
        case .component: return nil
        }
        if let l = t.frame.link { fill.link = l } else { fill.frame = t.frame.id }
        return fill
    }

    /// Puts a fill on a frame (a linked frame's whole group), replacing what was there; nil empties it. No undo
    /// step of its own: callers wrap it in one.
    func setFill(_ fill: Fill?, of t: FrameTarget) {
        guard let k = issue.layout?.pages[safe: t.page]?.components.firstIndex(where: { $0.id == t.placed }) else { return }
        var c = issue.layout!.pages[t.page].components[k]
        let covers = covering(t)
        c.fills.removeAll(where: covers)
        if let fill { c.fills.append(fill) }
        issue.layout!.pages[t.page].components[k] = c
    }

    /// Whether a fill is one a frame could show: by the frame's link letter, or keyed to the frame itself or to
    /// another frame of its group (a fill carried over from a version where the frames were linked differently).
    func covering(_ t: FrameTarget) -> (Fill) -> Bool {
        let group: Set<Frame.ID> = t.frame.link.flatMap { l in resolvedComponent(t.placed).map { Set($0.version.frames.filter { $0.link == l }.map(\.id)) } } ?? [t.frame.id]
        return { f in (t.frame.link != nil && f.link == t.frame.link) || (f.link == nil && f.frame.map { group.union([t.frame.id]).contains($0) } == true) }
    }

    /// Lets go of every fill holding a story or an ad that's been deleted.
    func dropFills(article: Article.ID? = nil, extra: Extra.ID? = nil) {
        guard issue.layout != nil else { return }
        for i in issue.layout!.pages.indices {
            for k in issue.layout!.pages[i].components.indices {
                issue.layout!.pages[i].components[k].fills.removeAll { (article != nil && $0.article == article) || (extra != nil && $0.extra == extra) }
            }
        }
    }

    /// The fill a frame shows, if any.
    func fill(of t: FrameTarget) -> Fill? {
        placedComponent(t.placed)?.placed.fill(for: t.frame)
    }

    /// Empties a frame (a linked frame's whole group). What it held goes back to the sidebar.
    func clearFrame(_ t: FrameTarget) {
        guard fill(of: t) != nil else { return }
        edit("Clear Frame") { setFill(nil, of: t) }
    }

    /// Every frame of a placed component, with its place on the page, in draw order.
    func frameTargets(_ id: PlacedComponent.ID) -> [FrameTarget] {
        guard let (page, _) = placedComponent(id), let rc = resolvedComponent(id) else { return [] }
        return rc.version.frames.filter { !$0.type.isIssueField }.map { FrameTarget(placed: id, page: page, frame: $0, rect: rc.rect($0.box)) }
    }

    /// What a dragged-out fill is, as the sidebar item it came from.
    func dragItem(for fill: Fill, in f: Frame) -> DragItem? {
        if let e = fill.extra { return .extra(e) }
        guard let a = fill.article else { return nil }
        if f.type == .image, let p = fill.photo { return .photo(a, p) }
        if f.type == .pullQuote { return .quote(a) }
        return .story(a)
    }

    /// What a frame's fill says, for the inspector and the warnings.
    func describe(_ fill: Fill) -> String {
        if let e = extra(fill.extra) { return e.title.isEmpty ? e.kind.rawValue : e.title }
        return article(fill.article)?.plainHeadline ?? "Missing story"
    }

    // MARK: pictures in image frames

    /// The picture an image frame shows.
    func picture(in t: FrameTarget) -> NSImage? {
        guard t.frame.type == .image, let fill = fill(of: t) else { return nil }
        if let e = extra(fill.extra) { return composer.image(e.path) }
        guard let a = article(fill.article), let p = a.photos.first(where: { $0.id == fill.photo }) ?? a.photos.first else { return nil }
        return composer.image(p.path)
    }

    /// How much of its picture an image frame hides, in page points, on each axis.
    func hidden(in t: FrameTarget) -> CGSize {
        guard let img = picture(in: t), img.size.width > 0, img.size.height > 0 else { return .zero }
        let r = t.rect
        let s = max(r.width / img.size.width, r.height / img.size.height)
        return CGSize(width: max(0, img.size.width * s - r.width), height: max(0, img.size.height * s - r.height))
    }

    /// Slides the picture in an image frame (its fill's focus, 0…1 on each axis), as a photo's crop slides.
    func setFillFocus(_ t: FrameTarget, focus: CGPoint) {
        guard let k = issue.layout?.pages[safe: t.page]?.components.firstIndex(where: { $0.id == t.placed }) else { return }
        let c = issue.layout!.pages[t.page].components[k]
        guard let shown = c.fill(for: t.frame), let i = c.fills.firstIndex(of: shown) else { return }
        issue.layout!.pages[t.page].components[k].fills[i].focusX = focus.x.clamped(0, 1)
        issue.layout!.pages[t.page].components[k].fills[i].focusY = focus.y.clamped(0, 1)
        if !editingNow { scheduleSave() }
    }

    func centerCrop(_ t: FrameTarget) { edit("Center Crop") { setFillFocus(t, focus: CGPoint(x: 0.5, y: 0.5)) } }

    // MARK: switching versions

    /// The versions a placed component can switch to: every one the catalogue knows.
    func versions(for p: PlacedComponent) -> [Int] {
        (catalogComponent(p.component)?.versions.map(\.number) ?? [p.version]).sorted()
    }

    /// The fills a placed component keeps on another version: those whose link letter is still there, and those
    /// whose frame (by id) is, keyed as the new version has that frame (by its letter if it's linked there, by
    /// itself if not). A letter that's gone hands its fill to the frames of its old group that are still there.
    func carriedFills(_ p: PlacedComponent, to v: ComponentVersion) -> [Fill] {
        let links = Set(v.frames.compactMap(\.link))
        let old = issue.version(of: p)?.frames ?? []
        var out: [Fill] = []
        func add(_ f: Fill) { if !out.contains(where: { $0.link == f.link && $0.frame == f.frame }) { out.append(f) } }
        for f in p.fills {
            if let l = f.link, links.contains(l) { add(f); continue }
            let was: [Frame.ID] = f.link.map { l in old.filter { $0.link == l }.map(\.id) } ?? f.frame.map { [$0] } ?? []
            for fr in v.frames where was.contains(fr.id) {
                var g = f
                if let l = fr.link { g.link = l; g.frame = nil } else { g.link = nil; g.frame = fr.id }
                add(g)
            }
        }
        return out
    }

    /// The stories that run in the issue, as the sidebar counts them (not On Hold): in a story block, or in a
    /// component's body or whole-story frame. With `id`, as if that placed component drew version `v` with `fills`.
    func runningStories(switching id: PlacedComponent.ID? = nil, to v: ComponentVersion? = nil, fills: [Fill] = []) -> Set<Article.ID> {
        var out = Set((issue.layout?.pages ?? []).flatMap { $0.stories.map(\.article) })
        for page in issue.layout?.pages ?? [] {
            for c in page.components {
                var q = c
                if c.id == id { q.fills = fills }
                guard let ver = c.id == id ? v : issue.version(of: c) else { continue }
                for f in ver.frames where f.type.setsAsBlock { if let a = q.fill(for: f)?.article { out.insert(a) } }
            }
        }
        return out.filter { article($0) != nil }
    }

    /// What switching a placed component to version `n` would undo: the stories that would go back on hold
    /// (they run nowhere else), then the other things its frames would let go of.
    func switchVersionLosses(_ id: PlacedComponent.ID, to n: Int) -> (onHold: [String], emptied: [String]) {
        guard let (_, p) = placedComponent(id), let v = catalogComponent(p.component)?.version(n) else { return ([], []) }
        let kept = carriedFills(p, to: v)
        // a story goes back on hold when it runs now (as the sidebar counts it) and won't after the switch
        let before = runningStories(), after = runningStories(switching: id, to: v, fills: kept)
        var onHold: [String] = [], emptied: [String] = []
        for f in p.fills {
            if let a = f.article, before.contains(a), !after.contains(a) {
                let name = describe(f)
                if !onHold.contains(name) { onHold.append(name) }
            }
        }
        for f in p.fills where !kept.contains(where: { $0.article == f.article && $0.extra == f.extra && $0.photo == f.photo }) {
            guard f.extra.map({ extra($0) != nil }) ?? (article(f.article) != nil) else { continue }      // deleted: nothing to list
            let name = describe(f)
            if !onHold.contains(name), !emptied.contains(name) { emptied.append(name) }
        }
        return (onHold, emptied)
    }

    /// Switches a placed component to another version (dropping any custom copy). Its fills carry over by frame
    /// and link letter; the frame keeps its place and its stretch.
    func switchVersion(_ id: PlacedComponent.ID, to n: Int) {
        guard let (page, p) = placedComponent(id), let c = catalogComponent(p.component), let v = c.version(n),
              let old = issue.version(of: p), let k = issue.layout?.pages[page].components.firstIndex(where: { $0.id == id }) else { return }
        guard n != p.version || p.custom != nil else { return }
        let sx = p.frame.w / max(1, old.width), sy = p.frame.h / max(1, old.height)
        edit("Switch Version") {
            issue.embed(c, version: n)
            var q = p
            q.version = n
            q.custom = nil
            q.fills = carriedFills(p, to: v)
            q.frame = Box(x: p.frame.x, y: p.frame.y, w: v.width * sx, h: v.height * sy)
            issue.layout!.pages[page].components[k] = q          // the old version's copy stays, for undo
        }
    }

    /// Switch Version…, after a warning that says what would go back on hold.
    func confirmSwitchVersion(_ id: PlacedComponent.ID, to n: Int) {
        guard let (_, p) = placedComponent(id) else { return }
        let (onHold, emptied) = switchVersionLosses(id, to: n)
        let alert = NSAlert()
        let name = issue.componentName(p.component) ?? "the component"
        alert.messageText = "Switch \(name) to version \(n)?"
        var info = "The new version may not have the same frames, so this might break things on the page."
        if !onHold.isEmpty { info += "\n\nThese go back to On Hold:\n" + onHold.map { "• \($0)" }.joined(separator: "\n") }
        if !emptied.isEmpty { info += "\n\nThese leave this component:\n" + emptied.map { "• \($0)" }.joined(separator: "\n") }
        if onHold.isEmpty && emptied.isEmpty { info += "\n\nEverything in its frames carries over." }
        alert.informativeText = info
        alert.addButton(withTitle: "Switch to v\(n)")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { switchVersion(id, to: n) }
    }

    // MARK: empty frames at export

    /// How many frames on the paper are empty: on screen they show their placeholder; in print they're blank.
    func emptyFrameCount() -> Int {
        composedPages.reduce(0) { n, p in n + p.ops.filter { if case .placeholder = $0 { true } else { false } }.count }
    }

    /// Export PDF and Export for InDesign ask first when frames are empty. True to go on.
    func confirmExportWithEmptyFrames(_ what: String) -> Bool {
        let n = emptyFrameCount()
        guard n > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = n == 1 ? "1 frame is empty" : "\(n) frames are empty"
        alert.informativeText = "Empty frames show a rainbow on screen only. In the \(what) they'll be left blank."
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
