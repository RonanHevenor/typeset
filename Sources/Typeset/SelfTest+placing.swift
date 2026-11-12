import AppKit

/// Phase 5 (components on the page) checks, driven through the hit test and the pointer state machine at page
/// points, as SelfTest+canvas does: placing a component from the sidebar, clicking, moving, resizing, deleting and
/// dragging it off; filling its frames (a linked group, a photo exactly on the line between two frames), clearing
/// and moving a frame's content, sliding a picture in a frame; a component over a story (and the Header over a
/// selected story's top band, IB-7); a story that starts in a body frame and jumps; switching versions; empty
/// frames; and the InDesign group. Built on two cleared inside pages of the seed issue; everything is put back.
extension SelfTest {
    @MainActor
    static func placingChecks(_ store: IssueStore, data: URL, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3 else { check("placing: a generated issue with three pages", false); return }
        let illustrated = store.issue.articles.filter { !$0.photos.isEmpty && $0.body.count > 3 }
        guard illustrated.count >= 3, let long = store.issue.articles.max(by: { $0.wordCount < $1.wordCount }) else {
            check("placing: three illustrated stories and a long one", false); return
        }
        let others = illustrated.filter { $0.id != long.id }
        guard others.count >= 2 else { check("placing: two illustrated stories besides the longest", false); return }
        let a = others[0], b = others[1]

        // undo as the app has it, one step per menu pick or gesture: the self-test runs in one turn of the run loop,
        // so an event-grouped manager would put every edit since fresh() in one group and one undo would revert them
        // all. This manager doesn't group by event; every command that registers undo runs in step {}, its own group
        // (as SelfTest+header does), and nothing is registered outside one.
        let saved = store.issue, savedZoom = store.zoom, savedUndo = store.undoManager
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.zoom = 1
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        defer {
            step { store.pointerCancelled() }
            store.issue = saved; store.zoom = savedZoom; store.undoManager = savedUndo; store.canvasSelection = nil
        }
        let pg = layout.pages.count - 1, pg2 = layout.pages.count - 2
        step { store.edit("Stage") {
            for i in [pg, pg2] {
                store.issue.layout!.pages[i].stories = []
                store.issue.layout!.pages[i].insets = []
                store.issue.layout!.pages[i].components = []
            }
        } }
        func fresh() { step { store.pointerCancelled() }; undo.removeAllActions(); store.canvasSelection = nil }
        // a gesture is one step, as in the app (a drag's end closes its own group too; a drop off the canvas or a
        // carried frame content registers through edit, so the gesture needs the group around it)
        func drag(_ from: CGPoint, by d: CGSize, on page: Int, to target: IssueStore.PointerLocation? = nil, mods: IssueStore.PointerModifiers = []) { step {
            store.pointerDown(at: from, on: page, modifiers: mods)
            let to = CGPoint(x: from.x + d.width, y: from.y + d.height)
            store.pointerMoved(to: .page(page, CGPoint(x: from.x + d.width / 2, y: from.y + d.height / 2)), modifiers: mods)
            store.pointerMoved(to: target ?? .page(page, to), modifiers: mods)
            store.pointerUp(at: target ?? .page(page, to), modifiers: mods)
        } }
        func r(_ x: CGRect?) -> String { x.map { String(format: "%.1f,%.1f %.1fx%.1f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none" }
        func near(_ x: CGRect?, _ y: CGRect, _ e: CGFloat = 0.01) -> Bool {
            guard let x else { return false }
            return abs(x.minX - y.minX) < e && abs(x.minY - y.minY) < e && abs(x.width - y.width) < e && abs(x.height - y.height) < e
        }

        // a card: headline and picture linked as A, two unlinked image frames side by side (L | R, sharing an
        // edge), a body frame; a rule along the top. Version 2 keeps A's frames only.
        let head = Frame(type: .headline, box: Box(x: 0, y: 0, w: 300, h: 30), link: "A", size: 24)
        let picA = Frame(type: .image, box: Box(x: 0, y: 34, w: 140, h: 80), link: "A")
        let left = Frame(type: .image, box: Box(x: 150, y: 34, w: 75, h: 80))
        let right = Frame(type: .image, box: Box(x: 225, y: 34, w: 75, h: 80))
        let body = Frame(type: .body, box: Box(x: 0, y: 120, w: 300, h: 80))
        let rule = LineElement(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 0))
        let v1 = ComponentVersion(number: 1, width: 300, height: 200, columns: 2, gutter: 12,
                                  elements: [.line(rule), .frame(head), .frame(picA), .frame(left), .frame(right), .frame(body)])
        let v2 = ComponentVersion(number: 2, width: 300, height: 120, columns: 2, gutter: 12, elements: [.frame(head), .frame(picA)])
        let card = Component(name: "Test Card", versions: [v1, v2])
        store.issue.embed(card, version: 1)
        store.issue.embed(card, version: 2)          // in the issue, so the catalogue offers it as the sidebar would
        check("placing: the catalogue lists the shipped components and one the issue carries, with its versions",
              store.componentCatalog().contains { $0.id == BuiltInComponents.headerID } && store.catalogComponent(card.id)?.versions.map(\.number) == [1, 2])

        // placing: a drag from the sidebar row, let go on the page
        fresh()
        let dropAt = CGPoint(x: 120, y: 300)
        let preview = store.frame(for: .component(card.id, 1), on: pg, at: dropAt)
        check("placing: the dashed preview is the component's size, where it's let go", preview.map { abs($0.width - 300) < 0.01 && abs($0.height - 200) < 0.01 && abs($0.minX - dropAt.x) < 20 && abs($0.minY - dropAt.y) < 30 } ?? false, r(preview))
        let ok = step { store.place(.component(card.id, 1), on: pg, at: dropAt) }
        guard ok, let placed = store.issue.layout?.pages[pg].components.last, placed.component == card.id else {
            check("placing: dropping a component row on a page places it", false); return
        }
        let id = placed.id
        func frame() -> CGRect? { store.placedComponent(id)?.placed.frame.rect }
        check("placing: dropping a component row on a page places it, at the preview, selected", near(frame(), preview ?? .zero) && store.canvasSelection == .component(id), r(frame()))
        check("  its label reads \"Test Card v1\"", store.componentLabel(placed) == "Test Card v1", store.componentLabel(placed))
        check("  the sidebar row says where it runs", store.componentRuns(card.id) == ["Page \(pg + 1) · v1"], "\(store.componentRuns(card.id))")
        undo.undo()
        check("  one undo step takes it off", store.placedComponent(id) == nil)
        undo.redo()
        guard let f0 = frame() else { check("  and redo puts it back", false); return }
        let rc0 = store.resolvedComponent(id)!

        // clicking: anywhere on it, frames included, selects the component; empty paper clears
        fresh()
        let inPicA = CGPoint(x: rc0.rect(picA.box).midX, y: rc0.rect(picA.box).midY)
        let hit = store.hit(at: inPicA, on: pg)
        check("rule 2: a component is its frame: over one of its frames the hit is the component", hit.what == .component(id) && hit.shape == f0, "\(hit.what)")
        store.pointerHover(at: inPicA, on: pg)
        check("rule 1: hovering doesn't select it", store.canvasSelection == nil)
        drag(inPicA, by: .zero, on: pg)
        check("rule 1: a click on a frame selects the component, not the frame", store.canvasSelection == .component(id) && store.pointer.frame == nil)
        drag(CGPoint(x: f0.minX - 30, y: f0.maxY + 60), by: .zero, on: pg)
        check("  a click on empty paper clears it", store.canvasSelection == nil)

        // moving: a drag on an unselected component selects and moves it, one undo step
        fresh()
        let c0 = CGPoint(x: f0.midX, y: f0.midY)
        drag(c0, by: CGSize(width: 40, height: 30), on: pg, mods: [.command])
        check("moving: dragging an unselected component selects and moves it (⌘: no snapping)",
              near(frame(), f0.offsetBy(dx: 40, dy: 30)) && store.canvasSelection == .component(id), r(frame()))
        undo.undo()
        check("  one undo step puts it back", near(frame(), f0) && !undo.canUndo, r(frame()))
        drag(c0, by: CGSize(width: 2, height: 1), on: pg)
        check("  a move under the drag threshold is a click: nothing moves", near(frame(), f0), r(frame()))
        drag(c0, by: CGSize(width: 0, height: 80), on: pg, mods: [.command, .shift])
        check("  ⇧ holds it to one axis", abs(frame()!.minX - f0.minX) < 0.01 && abs(frame()!.minY - f0.minY - 80) < 0.01, r(frame()))
        undo.undo()

        // onto another page, and a lost drag
        fresh()
        drag(c0, by: CGSize(width: 10, height: 10), on: pg, to: .page(pg2, CGPoint(x: c0.x + 10, y: c0.y + 10)), mods: [.command])
        check("moving: a component dragged onto another page goes there, one undo step", store.placedComponent(id)?.page == pg2, "page \(store.placedComponent(id).map { $0.page + 1 } ?? 0)")
        undo.undo()
        check("  and comes back with undo", store.placedComponent(id)?.page == pg && near(frame(), f0))
        fresh()
        step {
            store.pointerDown(at: c0, on: pg, modifiers: [.command])
            store.pointerMoved(to: .page(pg, CGPoint(x: c0.x + 25, y: c0.y)), modifiers: [.command])
            store.pointerCancelled()
        }
        check("rule 6: a lost mouse-up leaves it where it was dropped, nothing mid-drag, one undo step",
              near(frame(), f0.offsetBy(dx: 25, dy: 0)) && !store.pointer.isActive && store.dragging == nil, r(frame()))
        undo.undo()
        check("  (stage restored)", near(frame(), f0))

        // resizing: the selected component's edges; frames scale, type doesn't; snapping to the margin
        let headTarget = IssueStore.FrameTarget(placed: id, page: pg, frame: head, rect: rc0.rect(head.box))
        step { store.edit("Stage") { store.setFill(Fill(link: "A", article: a.id), of: headTarget) } }     // a headline to measure
        fresh()
        store.canvasSelection = .component(id)
        let east = CGPoint(x: f0.maxX - 2, y: f0.midY)
        check("rule 4: the selected component's edge is live, with its resize cursor", store.hit(at: east, on: pg).edge == .e)
        store.canvasSelection = nil
        check("  an unselected component has no edges", store.hit(at: east, on: pg).edge == nil)
        store.canvasSelection = .component(id)
        drag(east, by: CGSize(width: 60, height: 0), on: pg, mods: [.command])
        let f1 = frame()
        check("resizing: pulling the east edge widens it", f1.map { abs($0.width - 360) < 0.01 && abs($0.height - 200) < 0.01 && abs($0.minX - f0.minX) < 0.01 } ?? false, r(f1))
        if let rc = store.resolvedComponent(id) {
            let headRect = rc.rect(head.box)
            // the headline frame sets its lines as a block's headline (phase 7): a flow from the frame's corner
            let ops = store.composedPages[pg].ops
            let fonts = SelfTest.headlineFlow(in: headRect, ops).flatMap(\.font).map { [$0] } ?? []
            check("  its frames stretch with it (decision 6)", abs(rc.scaleX - 1.2) < 0.001 && abs(headRect.width - 360) < 0.01, String(format: "scale %.3f", rc.scaleX))
            check("  and its type keeps its size", !fonts.isEmpty && fonts.allSatisfy { abs($0.pointSize - 24) < 0.01 },
                  "\(fonts.map(\.pointSize)); frame \(headRect); flows: \(SelfTest.describeFlows(ops))")
        }
        undo.undo()
        check("  one undo step", near(frame(), f0) && !undo.canUndo, r(frame()))
        let liveRight = HouseStyle.margin + HouseStyle.liveWidth
        drag(east, by: CGSize(width: liveRight - 3 - f0.maxX, height: 0), on: pg)
        check("  an edge pulled near the margin snaps to it", abs((frame()?.maxX ?? 0) - liveRight) < 0.01, r(frame()))
        undo.undo()
        step { store.edit("Stage") { store.setFill(nil, of: headTarget) } }

        // Delete, and off the canvas
        fresh()
        store.canvasSelection = .component(id)
        step { store.deleteSelection() }
        check("Delete takes the selected component off", store.placedComponent(id) == nil && store.canvasSelection == nil)
        undo.undo()
        check("  undo brings it back", near(frame(), f0))
        fresh()
        step {
            store.pointerDown(at: c0, on: pg)
            store.pointerMoved(to: .page(pg, CGPoint(x: c0.x + 20, y: c0.y)))
            store.pointerMoved(to: .inspector)
        }
        check("  dragged over the sidebar it's shown at home until let go", store.dragOutside && near(frame(), f0))
        step { store.pointerUp(at: .inspector) }
        check("dragged off the canvas, it comes off the page", store.placedComponent(id) == nil)
        undo.undo()
        check("  undo brings it back", near(frame(), f0))

        // filling: a story on a linked frame fills its group; a photo on the line between two frames fills one
        fresh()
        let rc = store.resolvedComponent(id)!
        let headRect = rc.rect(head.box), aRect = rc.rect(picA.box), lRect = rc.rect(left.box), rRect = rc.rect(right.box), bodyRect = rc.rect(body.box)
        let atHead = CGPoint(x: headRect.midX, y: headRect.midY)
        check("filling: over a frame that takes it, the preview is the frame", near(store.frame(for: .story(a.id), on: pg, at: atHead), headRect), r(store.frame(for: .story(a.id), on: pg, at: atHead)))
        step { store.place(.story(a.id), on: pg, at: atHead) }
        let p1 = store.placedComponent(id)!.placed
        check("  a story dropped on a linked headline frame fills the group by its letter", p1.fill(for: head)?.article == a.id && p1.fill(for: picA)?.article == a.id && p1.fills.count == 1)
        let ops1 = store.composedPages[pg].ops
        let drewHead = SelfTest.headlineFlow(in: headRect, ops1)?.text.contains(a.plainHeadline.trimmed.prefix(12)) == true
        let drewPic = ops1.contains { if case let .image(_, rr, _, _) = $0 { rr == aRect } else { if case let .missing(rr) = $0 { rr == aRect } else { false } } }
        check("  the headline frame shows its headline, the image frame its picture", drewHead && drewPic,
              "headline \(drewHead) picture \(drewPic); frame \(headRect); flows: \(SelfTest.describeFlows(ops1))")
        check("  the page's stories aren't touched: no story block was added", store.issue.layout!.pages[pg].stories.isEmpty)
        undo.undo()
        check("  one undo step empties it", store.placedComponent(id)!.placed.fills.isEmpty)
        let photo = b.photos[0]
        let boundary = CGPoint(x: lRect.maxX, y: lRect.midY)
        check("filling: the line between two frames is exactly shared", abs(lRect.maxX - rRect.minX) < 0.0001)
        let pv = store.frame(for: .photo(b.id, photo.id), on: pg, at: boundary)
        step { store.place(.photo(b.id, photo.id), on: pg, at: boundary) }
        let p2 = store.placedComponent(id)!.placed
        check("  a photo dropped exactly on it fills one frame, the one right of the line, as previewed",
              p2.fill(for: right)?.photo == photo.id && p2.fill(for: left) == nil && p2.fills.count == 1 && near(pv, rRect), "\(p2.fills.count) fills, preview \(r(pv))")
        check("  a frame that doesn't take an item isn't a target: a pull quote over an image frame places as usual",
              store.frameTarget(at: CGPoint(x: lRect.midX, y: lRect.midY), on: pg, for: .quote(b.id)) == nil)

        // sliding the picture in a frame; Center the Crop
        fresh()
        store.canvasSelection = .component(id)
        let inR = CGPoint(x: rRect.midX, y: rRect.midY)
        let t = store.frameTarget(at: inR, on: pg)!
        let hidden = store.hidden(in: t)
        if store.picture(in: t) != nil, hidden.width + hidden.height > 0.5 {
            drag(inR, by: CGSize(width: 20, height: 20), on: pg, mods: [.command])
            let focus = store.fill(of: t)?.focus ?? CGPoint(x: 0.5, y: 0.5)
            check("cropping: ⌘-drag inside a picture in a selected component's frame slides its crop, not the component",
                  near(frame(), f0) && focus != CGPoint(x: 0.5, y: 0.5), "focus \(focus) hidden \(hidden)")
            check("  one undo step", undo.canUndo && { undo.undo(); return store.fill(of: t)?.focus == CGPoint(x: 0.5, y: 0.5) && !undo.canUndo }())
        } else {
            check("cropping: ⌘-drag inside a picture in a component's frame slides its crop", true, "the photo's file isn't here to crop; skipped")
        }
        store.setFillFocus(t, focus: CGPoint(x: 0.1, y: 0.9))
        step { store.centerCrop(t) }
        check("  Center the Crop puts it back in the middle", store.fill(of: t)?.focus == CGPoint(x: 0.5, y: 0.5))

        // clearing: ⌥-drag a frame's content off the component; onto another frame it moves
        fresh()
        store.canvasSelection = .component(id)
        drag(inR, by: CGSize(width: -(rRect.midX - lRect.midX), height: 0), on: pg, mods: [.option])
        let p3 = store.placedComponent(id)!.placed
        check("clearing: ⌥-dragging a frame's picture onto the next frame moves it there, one step",
              p3.fill(for: left)?.photo == photo.id && p3.fill(for: right) == nil && near(frame(), f0))
        undo.undo()
        drag(inR, by: CGSize(width: 0, height: f0.maxY - inR.y + 60), on: pg, mods: [.option])
        check("  ⌥-dragged off the component, the frame is cleared, and the component stays put",
              store.placedComponent(id)!.placed.fill(for: right) == nil && near(frame(), f0))
        undo.undo()
        check("  undo puts it back", store.placedComponent(id)!.placed.fill(for: right)?.photo == photo.id)
        step {
            store.pointerDown(at: inR, on: pg, modifiers: [.option])
            store.pointerMoved(to: .page(pg, CGPoint(x: inR.x, y: inR.y + 300)), modifiers: [.option])
            store.pointerCancelled()
        }
        check("rule 6: a carried frame content whose mouse-up is lost stays in its frame", store.placedComponent(id)!.placed.fill(for: right)?.photo == photo.id && !store.pointer.isActive)

        // empty frames: a placeholder on screen only
        let ops2 = store.composedPages[pg].ops
        let holders = ops2.compactMap { if case let .placeholder(rr, type) = $0 { (rr, type) } else { nil } }
        check("empty frames: each empty frame leaves a screen-only placeholder; a filled one doesn't",
              holders.contains { $0.0 == bodyRect && $0.1 == .body } && holders.contains { $0.0 == lRect && $0.1 == .image } && !holders.contains { $0.0 == rRect },
              "\(holders.map { $0.1.rawValue })")
        check("  and the export counts them to warn", store.emptyFrameCount() >= 3, "\(store.emptyFrameCount())")

        // a component over a story: the component is on top where they overlap
        fresh()
        guard let sb = step({ store.addBlock(a.id, on: pg) }) else { check("overlap: a story block to try", false); return }
        let sFrame = CGRect(x: f0.minX, y: f0.maxY - 4, width: f0.width, height: 200)
        step { store.edit("Stage") { store.setBlockFrame(sb, page: pg, frame: sFrame) } }
        let both = CGPoint(x: f0.midX, y: f0.maxY - 2)
        check("rule 3: where a component and a story overlap, the component is on top", store.hit(at: both, on: pg).what == .component(id))
        store.canvasSelection = .block(sb)
        let band = store.hit(at: both, on: pg)
        check("  a selected story's top band yields to it", band.edge == nil && band.what == .component(id), "\(band.what) \(String(describing: band.edge))")
        check("  and is live just outside it", store.hit(at: CGPoint(x: f0.midX, y: sFrame.minY + 6), on: pg).edge == .n)
        drag(both, by: .zero, on: pg)
        check("  a click there selects the component", store.canvasSelection == .component(id))
        step { store.removeBlock(sb) }

        // IB-7 carried over: the Header's frames over a selected story's top band (page 1)
        fresh()
        if let header = store.issue.header(on: 0), let hf = store.displayPages[0].componentFrames[header.id],
           let lead = store.issue.layout!.pages[0].stories.first {
            let staged = CGRect(x: lead.frame.x, y: hf.maxY - 4, width: lead.frame.w, height: lead.frame.h)
            step { store.edit("Stage") { store.setBlockFrame(lead.id, page: 0, frame: staged) } }
            store.canvasSelection = .block(lead.id)
            let x = max(staged.minX, hf.minX) + 20
            let over = store.hit(at: CGPoint(x: x, y: hf.maxY - 2), on: 0)
            check("IB-7 the Header over a selected story's top band: the Header is under the pointer, no resize edge",
                  over.what == .component(header.id) && over.edge == nil, "\(over.what) \(String(describing: over.edge))")
            check("  just below the Header the story's top edge is live", store.hit(at: CGPoint(x: x, y: hf.maxY + 2), on: 0).edge == .n)
            undo.undo()
        } else {
            check("IB-7 the Header over a selected story's top band", false, "no Header on page 1")
        }

        // a story that starts in a body frame and jumps to a block on a later page (the plan's open question)
        fresh()
        step { store.parkStory(long.id) }
        let jumpCard = Component(name: "Jump Card", versions: [ComponentVersion(number: 1, width: 300, height: 120, columns: 2, gutter: 12,
                                                                               elements: [.frame(Frame(type: .body, box: Box(x: 0, y: 0, w: 300, h: 120)))])])
        store.issue.embed(jumpCard, version: 1)
        let jid = step { store.placeComponent(jumpCard.id, version: 1, on: pg2, at: CGPoint(x: 120, y: 400)) }
        if let jid, let jrc = store.resolvedComponent(jid), let bf = jrc.version.frames.first {
            let jr = jrc.rect(bf.box)
            step { store.place(.story(long.id), on: pg2, at: CGPoint(x: jr.midX, y: jr.midY)) }
            let later = step { store.addBlock(long.id, on: pg) }
            let pages = store.composedPages
            let inFrame = pages[pg2].componentBlockResults[jid]?[bf.id]
            let onward = later.flatMap { pages[pg].blockResults[$0] }
            check("jumping: a story dropped on a body frame starts there", inFrame?.start == 0 && (inFrame?.used ?? 0) > 0, "\(String(describing: inFrame.map { ($0.start, $0.used) }))")
            check("  and jumps from it to its block on a later page", inFrame?.jumped == true && inFrame?.jumpTo == pg + 1 && onward?.start == inFrame?.end && onward?.continuedFrom == pg2 + 1,
                  "jumped \(String(describing: inFrame?.jumped)) to \(String(describing: inFrame?.jumpTo)); onward starts \(String(describing: onward?.start)) of end \(String(describing: inFrame?.end))")
            let st = store.storyStatus()[long.id]
            check("  the sidebar shows it running on both pages, not on hold", st?.pages == [pg2 + 1, pg + 1], "\(String(describing: st?.pages))")

            // InDesign: the component as a group, and the body frame's text threaded into the story
            do {
                let (spreads, stories) = try readIDML(store.issue, composer: store.composer, to: data.appendingPathComponent("selftest-placing.idml"))
                check("IDML: a placed component is written as one group, named as its label",
                      spreads[pg].contains("<Group ") && spreads[pg].contains("Name=\"Test Card v1\""))
                let threaded = spreads[pg2].matches(of: #/<TextFrame Self="(\w+)" ParentStory="(\w+)" PreviousTextFrame="n" NextTextFrame="(\w+)"/#)
                // a plain word from the story's first paragraph, as the export writes it (soft hyphens dropped)
                let firstWords = long.body.first { !$0.trimmed.isEmpty }.flatMap { p in
                    Markup.plain(p).split(separator: " ").map(String.init).first { $0.count >= 4 && $0.allSatisfy(\.isLetter) }
                } ?? "?"
                func text(_ xml: String) -> String {
                    xml.matches(of: #/<Content>([^<]*)<\/Content>/#).map { String($0.1) }.joined().replacingOccurrences(of: "\u{AD}", with: "")
                }
                check("  and the story in its body frame is exported, threaded on to the later page",
                      threaded.contains { m in stories[String(m.2)].map { text($0).contains(firstWords) } ?? false }
                      && threaded.contains { m in spreads[pg].contains("Self=\"\(m.3)\"") }, "\(threaded.count) threaded frames start on page \(pg2 + 1); looking for \"\(firstWords)\"")
            } catch { check("IDML: the export with components placed", false, "\(error)") }
        } else {
            check("jumping: a body-frame component to drop the story on", false)
        }

        // switching versions: what goes back on hold, fills carried by frame and link letter
        fresh()
        step { store.place(.story(a.id), on: pg, at: atHead) }                 // A: kept by v2
        step { store.place(.story(long.id), on: pg, at: CGPoint(x: bodyRect.midX, y: bodyRect.midY)) }   // body: gone in v2
        let (onHold, emptied) = store.switchVersionLosses(id, to: 2)
        check("switching: the warning lists what goes back on hold and what leaves the component",
              (emptied + onHold).contains(b.plainHeadline) && !onHold.contains(a.plainHeadline) && !emptied.contains(a.plainHeadline),
              "on hold \(onHold), leaving \(emptied)")
        step { store.parkStory(long.id) }
        step { store.place(.story(long.id), on: pg, at: CGPoint(x: bodyRect.midX, y: bodyRect.midY)) }
        if let jid { step { store.removeComponent(jid) } }
        let (onHold2, _) = store.switchVersionLosses(id, to: 2)
        check("  a story that runs only in a dropped frame goes back on hold", onHold2.contains(long.plainHeadline), "\(onHold2)")
        step { store.switchVersion(id, to: 2) }
        let p4 = store.placedComponent(id)?.placed
        check("  switched: v2, fills carried by link letter, the rest let go",
              p4?.version == 2 && p4?.fill(for: head)?.article == a.id && p4?.fills.count == 1, "\(String(describing: p4?.fills.count)) fills")
        check("  the label follows", p4.map { store.componentLabel($0) } == "Test Card v2")
        check("  the issue keeps a copy of the old version, so undo can draw it", store.issue.componentVersions.first { $0.id == card.id }?.version(1) != nil)
        check("  with the frame keeping its place", abs((frame()?.minX ?? 0) - f0.minX) < 0.01 && abs((frame()?.height ?? 0) - 120) < 0.01, r(frame()))
        undo.undo()
        let p5 = store.placedComponent(id)?.placed
        check("  one undo step goes back to v1 with its fills, drawn", p5?.version == 1 && p5?.fills.count == 3 && store.resolvedComponent(id) != nil,
              "v\(p5.map { String($0.version) } ?? "–"), \(p5?.fills.count ?? -1) fills, drawn \(store.resolvedComponent(id) != nil)")
        var custom = store.placedComponent(id)!.placed
        custom.custom = v1
        check("  a custom copy is labelled \"Test Card custom\"", store.componentLabel(custom) == "Test Card custom")
        placingFixes(store, report, card: id, page: pg, page2: pg2, undo: undo, frames: (head, picA, left, right, body), a: a, b: b) { drag($0, by: $1, on: $2, mods: $3) }
    }

    /// Runs one command as one undo step, as a menu pick or a gesture is in the app, on a manager that doesn't group
    /// by event. A command that registered nothing leaves no step: an empty group would otherwise be one (each of the
    /// store's undo registrations names its step, so a group with no action name is empty) and is dropped.
    @MainActor @discardableResult
    static func undoStep<T>(_ undo: UndoManager, _ f: () -> T) -> T {
        precondition(!undo.groupsByEvent && undo.groupingLevel == 0, "undoStep: an event-grouped manager or a group left open")
        undo.beginUndoGrouping()
        let r = f()
        undo.endUndoGrouping()
        if undo.canUndo, undo.undoActionName.isEmpty { undo.undo() }     // empty: undoing it reverts nothing, leaves no redo
        return r
    }
}
