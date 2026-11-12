import AppKit

/// Phase 7 review fixes. Make Component on the generated paper's own pages, the whole page and each block, picture
/// and pull quote alone, sets every page as it was: every line of every headline and column, every label and every
/// rule, where it was (a two-line headline's second line, a neighbour held level with the made block, the rules
/// between stories, a story under the made one); a body frame on the page's columns sets in them when the
/// component's own columns are narrower; an item with nothing to draw stays on the page; a single item makes a
/// component. In place: undo past the editor's steps moves the editor with the placement; the drawing tools don't
/// draw on the faded page; a lost mouse-up closes the editor's gesture. Everything is put back.
extension SelfTest {
    /// Every line of type on a composed page and every rule: a `.flow` op line by line (its baseline), a `.text`
    /// op at its rect's corner, a `.line` op by its ends.
    static func everyLine(_ cp: ComposedPage) -> [(text: String, at: CGPoint)] {
        var out: [(text: String, at: CGPoint)] = []
        for op in cp.ops {
            switch op {
            case .text(let s, let r):
                if s.length > 0 { out.append((s.string, r.origin)) }
            case .flow(let lm, let tc, let origin):
                let g = lm.glyphRange(for: tc)
                guard g.length > 0, let st = lm.textStorage else { continue }
                lm.enumerateLineFragments(forGlyphRange: g) { rect, _, _, gr, _ in
                    let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                    out.append(((st.string as NSString).substring(with: cr), CGPoint(x: origin.x + rect.minX, y: origin.y + rect.minY + lm.location(forGlyphAt: gr.location).y)))
                }
            case .line(let a, let b, _, _):
                out.append((String(format: "rule to %.1f,%.1f", b.x, b.y), a))
            default: continue
            }
        }
        return out
    }

    @MainActor
    static func makeFixesChecks(_ store: IssueStore, data: URL, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3 else { check("make fixes: a generated issue", false); return }
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
        func reset() { store.closeInPlace(); store.issue = saved; undo.removeAllActions(); store.select([]) }
        func pagesNow() -> [[(text: String, at: CGPoint)]] { store.displayPages.map(everyLine) }
        func diff(_ a: [[(text: String, at: CGPoint)]], _ b: [[(text: String, at: CGPoint)]]) -> [String] {
            a.indices.flatMap { p in runDifferences(a[p], b[p], tolerance: 0.3).map { "page \(p + 1): " + $0 } }
        }

        // MARK: the paper's own pages

        let before = pagesNow()
        var failures: [String] = []
        var runs = 0, twoLineHeadlines = 0
        for (i, pl) in layout.pages.enumerated() {
            var selections: [(String, Set<LayoutSelection>)] = [("the whole page", Set(pl.stories.map { .block($0.id) } + pl.insets.map { .inset($0.id) }))]
            for (k, b) in pl.stories.enumerated() { selections.append(("block \(k + 1)", [.block(b.id)])) }
            for (k, s) in pl.insets.enumerated() { selections.append(("\(s.kind.rawValue) \(k + 1)", [.inset(s.id)])) }
            for (name, sel) in selections where !sel.isEmpty {
                reset()
                guard let made = step({ store.makeComponent(from: sel, name: "Check") }) else { failures.append("page \(i + 1), \(name): nothing made"); continue }
                store.closeInPlace()
                runs += 1
                if name == "the whole page", let v = store.placedComponent(made).flatMap({ store.issue.version(of: $0.placed) }) {
                    twoLineHeadlines += v.frames.filter { $0.type == .headline && ($0.size ?? 0) > 0 && $0.box.h > ($0.size ?? 0) * 1.6 }.count
                }
                let d = diff(before, pagesNow())
                if !d.isEmpty { failures.append("page \(i + 1), \(name): " + d.prefix(3).joined(separator: "; ")) }
            }
        }
        check("make fixes: Make Component on each page of the paper (the whole page, each block, picture and pull quote alone) sets every page as it was: every line, label and rule (\(runs) runs, \(twoLineHeadlines) two-line headlines)",
              failures.isEmpty && runs > layout.pages.count, failures.prefix(4).joined(separator: " | "))
        reset()

        // MARK: staged pages: a box that isn't column-aligned, items with nothing to draw, one item alone

        let g = store.grid
        let pg = layout.pages.count - 1
        let stories = saved.articles.filter { !$0.photos.isEmpty && $0.body.count > 3 && !$0.author.trimmed.isEmpty }
        guard g.columns >= 3, let s0 = stories.first, let s1 = saved.articles.first(where: { $0.id != s0.id && $0.body.count > 3 }) else {
            check("make fixes: a story with a photo and another story, three columns", false); return
        }
        let A = StoryBlock(article: s0.id, frame: Box(x: g.x(0), y: 120, w: g.span(2), h: 360), columns: 2, headlineSize: HouseStyle.headlineSize(columns: 2))
        // the photo isn't snapped: it ends in the middle of the third column
        let off = Inset(kind: .photo, article: s0.id, photo: s0.photos[0].id, frame: Box(x: g.x(2), y: 520, w: g.colWidth / 2, h: 80))
        let quote = Inset(kind: .pullQuote, article: s1.id, frame: Box(x: g.x(2), y: 120, w: g.colWidth, h: 60))
        let lost = Inset(kind: .photo, article: s0.id, photo: UUID(), frame: Box(x: g.x(2), y: 300, w: g.colWidth, h: 80))
        let stage: (inout Issue) -> Void = { issue in
            // the story comes off the rest of the paper first, so the block holds its start
            for i in issue.layout!.pages.indices {
                issue.layout!.pages[i].stories.removeAll { $0.article == s0.id }
                issue.layout!.pages[i].insets.removeAll { $0.article == s0.id }
            }
            issue.layout!.pages[pg].stories = [A]
            issue.layout!.pages[pg].insets = [off, quote, lost]
            issue.layout!.pages[pg].components = []
            if let k = issue.articles.firstIndex(where: { $0.id == s1.id }) { issue.articles[k].pullQuote = "" }   // a pull quote with nothing to say
        }
        var staged = saved
        stage(&staged)
        store.issue = staged
        let stagedBefore = pagesNow()
        let made = step { store.makeComponent(from: [.block(A.id), .inset(off.id), .inset(quote.id), .inset(lost.id)], name: "Off Grid") }
        store.closeInPlace()
        if let made, let (_, p) = store.placedComponent(made), let v = store.issue.version(of: p) {
            let body = store.componentBlocks(on: pg).first { $0.placed == made && $0.bodyOnly }
            check("make fixes: a box ending mid-column gets narrower columns of its own (\(v.columns ?? -1)), but the body frame on two of the page's columns sets in two",
                  v.columns == 3 && body?.block.columns == 2 && abs((body?.gutter ?? 0) - HouseStyle.gutter) < 0.01, "body sets in \(body?.block.columns ?? -1)")
            let d = diff(stagedBefore, pagesNow())
            check("  and the page sets as it did", d.isEmpty, d.prefix(4).joined(separator: "; "))
            check("make fixes: items with nothing to draw (a pull quote whose story has none, a photo gone from its story) stay on the page, and aren't in the box",
                  store.page(of: .inset(quote.id)) == pg && store.page(of: .inset(lost.id)) == pg && store.page(of: .inset(off.id)) == nil && store.page(of: .block(A.id)) == nil
                  && !v.frames.contains { $0.type == .pullQuote } && v.frames.filter { $0.type == .image }.count == 1)
        } else { check("make fixes: a component from a block and an off-grid photo", false) }
        undo.undo()
        check("  one undo puts it all back", store.page(of: .block(A.id)) == pg && store.page(of: .inset(off.id)) == pg && store.issue.layout!.pages[pg].components.isEmpty)
        undo.removeAllActions()
        let single = step { store.makeComponent(from: [.inset(off.id)], name: "One Photo") }
        check("make fixes: a single photo, alone, makes a component (the right-click menu offers it for one item)",
              single.flatMap { store.placedComponent($0) }.flatMap { store.issue.version(of: $0.placed) }?.frames.contains { $0.type == .image } == true && store.page(of: .inset(off.id)) == nil)
        store.closeInPlace()
        reset()

        // MARK: in place

        let card = Component(name: "Fix Card", versions: [ComponentVersion(number: 1, width: 200, height: 100,
                                                                           elements: [.rect(ShapeElement(box: Box(x: 10, y: 10, w: 40, h: 40), fill: .red))])])
        var cid = UUID()
        step { store.edit("Stage") {
            store.issue.layout!.pages[pg].stories = []
            store.issue.layout!.pages[pg].insets = []
            store.issue.layout!.pages[pg].components = []
            cid = store.issue.place(card, version: 1, on: pg, at: CGPoint(x: g.x(0), y: 200)) ?? cid
        } }
        undo.removeAllActions()
        let home = CGRect(x: g.x(0), y: 200, width: 200, height: 100)
        // setComponentFrame is the raw setter a gesture calls inside its own edit: alone it registers no undo, so
        // the move is made as a gesture makes it, a named step
        step { store.edit("Move Component") { store.setComponentFrame(cid, page: pg, frame: home.offsetBy(dx: 40, dy: 30)) } }
        check("  (staged: the component moved, one undo step)", store.placedComponent(cid)?.placed.frame.rect.origin == home.offsetBy(dx: 40, dy: 30).origin && undo.canUndo,
              "at \(String(describing: store.placedComponent(cid)?.placed.frame.rect.origin)), canUndo \(undo.canUndo)")
        step { _ = store.enterInPlace(cid) }
        guard let e = store.inPlace?.editor else { check("make fixes: in place on a placed component", false); return }
        check("in place: opened on a component just moved", e.origin == home.offsetBy(dx: 40, dy: 30).origin)
        undo.undo()                                           // reaches past the editor into the page: the move
        store.followInPlace()                                 // the canvas calls it on any layout change
        check("in place: an undo that reaches the page's move takes the editor with the placement",
              store.inPlace != nil && e.origin == home.origin && store.inPlace?.startOrigin == home.origin, "editor at \(e.origin)")
        step { store.leaveInPlace() }
        check("  leaving after it writes nothing stale: the placement stays where the undo put it, not custom",
              store.placedComponent(cid)?.placed.frame.rect.origin == home.origin && store.placedComponent(cid)?.placed.custom == nil,
              "at \(String(describing: store.placedComponent(cid)?.placed.frame.rect.origin)), custom \(store.placedComponent(cid)?.placed.custom != nil)")

        undo.removeAllActions()
        step { _ = store.enterInPlace(cid) }
        guard let e = store.inPlace?.editor else { check("make fixes: in place again", false); return }
        let count = e.draft.elements.count
        let outside = CGPoint(x: home.maxX + 80, y: home.maxY + 80)
        e.tool = .rect
        step { e.pointerDown(at: outside); e.pointerUp(at: outside) }
        e.tool = .rect
        step { e.pointerDown(at: outside); e.pointerMoved(to: CGPoint(x: outside.x + 30, y: outside.y + 30)); e.pointerUp(at: CGPoint(x: outside.x + 30, y: outside.y + 30)) }
        check("in place: a drawing tool's click or drag on the faded page outside the component draws nothing", e.draft.elements.count == count && !e.pointer.isActive)
        e.tool = .rect
        let inside = CGPoint(x: home.maxX - 30, y: home.maxY - 30)
        step { e.pointerDown(at: inside); e.pointerMoved(to: CGPoint(x: inside.x + 60, y: inside.y + 60)); e.pointerUp(at: CGPoint(x: inside.x + 60, y: inside.y + 60)) }
        let drawn = e.draft.elements.last.map { e.pageRect($0) }
        check("  one drawn from inside out to the paper stops at the component's edge",
              e.draft.elements.count == count + 1 && drawn.map { home.insetBy(dx: -0.01, dy: -0.01).contains($0) } == true, drawn.map { "\($0)" } ?? "none")
        e.tool = .rect
        let corner = CGPoint(x: home.maxX - 60, y: home.maxY - 40)
        step { e.pointerDown(at: corner); e.pointerUp(at: corner) }
        let clicked = e.draft.elements.last.map { e.pageRect($0) }
        check("  one put down by a click near the edge is kept inside it",
              e.draft.elements.count == count + 2 && clicked.map { home.insetBy(dx: -0.01, dy: -0.01).contains($0) } == true, clicked.map { "\($0)" } ?? "none")

        // rule 6 in place: the window loses key mid-drag
        let first = e.draft.elements.first.map { e.pageRect($0) } ?? .zero
        let grab = CGPoint(x: first.midX, y: first.midY)
        e.tool = .select
        undo.removeAllActions()
        undo.beginUndoGrouping()
        e.pointerDown(at: grab)
        e.pointerMoved(to: CGPoint(x: grab.x + 10, y: grab.y), modifiers: [.command])
        e.pointerMoved(to: CGPoint(x: grab.x + 20, y: grab.y), modifiers: [.command])
        let wasActive = e.pointer.isActive
        let closed = store.lostMouse()                        // what the page view does when the window resigns key
        undo.endUndoGrouping()
        let moved = e.draft.elements.first.map { e.pageRect($0) } ?? .zero
        check("rule 6 in place: the window losing key closes the editor's drag; the element stays where it was dropped, one undo step",
              wasActive && closed && !e.pointer.isActive && abs(moved.minX - (first.minX + 20)) < 0.01 && undo.canUndo, "x \(moved.minX) from \(first.minX)")
        undo.undo()
        check("  (one undo puts it back)", abs((e.draft.elements.first.map { e.pageRect($0) }?.minX ?? 0) - first.minX) < 0.01)
        check("  with no gesture open, losing key does nothing", !store.lostMouse())
        store.closeInPlace()
    }
}
