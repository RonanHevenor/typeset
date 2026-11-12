import AppKit

extension SelfTest {
    /// The headlines a page's component frames set (phase 7: a headline frame sets its lines as a block's headline
    /// does, a `.flow` drawn from the frame's corner, not a `.text` in its rect): text, origin, the container's
    /// width, and the first character's font.
    static func headlineFlows(_ ops: [DrawOp]) -> [(text: String, origin: CGPoint, width: CGFloat, font: NSFont?)] {
        ops.compactMap { op in
            guard case let .flow(lm, tc, origin) = op, let s = lm.textStorage else { return nil }
            return (s.string, origin, tc.size.width, s.length > 0 ? s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil)
        }
    }

    /// The headline set in the frame at `rect` (its corner and width), if any.
    static func headlineFlow(in rect: CGRect, _ ops: [DrawOp]) -> (text: String, origin: CGPoint, width: CGFloat, font: NSFont?)? {
        headlineFlows(ops).first { $0.origin == rect.origin && abs($0.width - rect.width) < 0.01 }
    }

    /// For a failed check: where the flows are.
    static func describeFlows(_ ops: [DrawOp]) -> String {
        headlineFlows(ops).map { "\"\($0.text.prefix(24))\" at \($0.origin.x),\($0.origin.y) w \($0.width) \($0.font?.pointSize ?? 0) pt" }.joined(separator: "; ")
    }
}

extension SelfTest {
    /// Components (phase 3): a component built in code, placed, drawn, set, saved and read back.
    @MainActor
    static func components(_ report: (String, Bool, String) -> Void, store: IssueStore, data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        var issue = store.issue
        // without the shipped Header and Folio (phase 4), so what's counted and placed here is the test component alone
        for i in issue.layout?.pages.indices ?? 0..<0 {
            issue.layout!.pages[i].components.removeAll { $0.component == BuiltInComponents.headerID || $0.component == BuiltInComponents.folioID }
        }
        issue.componentVersions = []
        guard let layout = issue.layout, layout.pages.count >= 3 else {
            check("components: the seed paper has three pages to try", false, "\(store.issue.layout?.pages.count ?? 0) pages"); return
        }
        let composer = store.composer

        // a folio-like component: a rule, preset text, a date in its own format, the desk, the page number, a red
        // box, an ellipse, a dot of art; and frames for a story: headline, image and caption linked as A, a body
        // frame, and a whole-story frame on its own
        let png: Data = {
            let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
            let tiff = img.tiffRepresentation!
            return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        }()
        let headline = Frame(type: .headline, box: Box(x: 0, y: 40, w: 300, h: 40), link: "A")
        let image = Frame(type: .image, box: Box(x: 320, y: 40, w: 200, h: 120), link: "A", outline: false)
        let caption = Frame(type: .caption, box: Box(x: 320, y: 164, w: 200, h: 30), link: "A")
        let body = Frame(type: .body, box: Box(x: 0, y: 90, w: 260, h: 150), link: "A")      // one of the component's two columns
        let whole = Frame(type: .wholeStory, box: Box(x: 0, y: 250, w: 540, h: 300))
        let dateFrame = Frame(type: .date, box: Box(x: 200, y: 0, w: 200, h: 16), alignment: .center, dateFormat: "yyyy-MM-dd")
        let v1 = ComponentVersion(number: 1, width: 540, height: 560, columns: 2, gutter: 20, elements: [
            .line(LineElement(from: CGPoint(x: 0, y: 18), to: CGPoint(x: 540, y: 18))),
            .text(TextElement(box: Box(x: 0, y: 0, w: 120, h: 16), text: "poly.rpi.edu")),
            .frame(dateFrame),
            .frame(Frame(type: .desk, box: Box(x: 400, y: 0, w: 100, h: 16))),
            .frame(Frame(type: .pageNumber, box: Box(x: 500, y: 0, w: 40, h: 16), alignment: .right)),
            .rect(ShapeElement(box: Box(x: 0, y: 20, w: 540, h: 18), fill: .red)),
            .ellipse(ShapeElement(box: Box(x: 250, y: 200, w: 40, h: 40), fill: nil, stroke: .ink, strokeWidth: 1)),
            .art(ArtElement(box: Box(x: 500, y: 200, w: 30, h: 30), name: "dot.png", data: png)),
            .frame(headline), .frame(image), .frame(caption), .frame(body), .frame(whole),
        ], date: Date(timeIntervalSince1970: 1_700_000_000))       // whole seconds: the file keeps no fraction
        var folio = Component(name: "Test Folio", versions: [v1])
        folio.versions.append(ComponentVersion(number: 2, width: 540, height: 560, elements: []))

        // the story to drop on it: taken off the paper first, so its only setting is in the component
        // the longest story with a picture, so it runs on past the frames it's given
        guard let story = issue.articles.filter({ a in !a.photos.isEmpty && layout.pages.contains { $0.stories.contains { $0.article == a.id } } }).max(by: { $0.wordCount < $1.wordCount }) else {
            check("components: a story with a picture to drop on a frame", false, ""); return
        }
        for i in issue.layout!.pages.indices {
            issue.layout!.pages[i].stories.removeAll { $0.article == story.id }
            issue.layout!.pages[i].insets.removeAll { $0.article == story.id }
        }
        // the paper is generated from a random seed each launch, and a component's frames keep clear of the page's
        // pictures: clear page 2's pictures from under where the component goes, so what it sets is the same every run
        let under = Composer.wrap(CGRect(x: 100, y: 300, width: 540, height: 560))
        issue.layout!.pages[1].insets.removeAll { Composer.wrap($0.frame.rect).intersects(under) }
        let before = composer.compose(issue).map { $0.ops.count }
        let fills = [Fill(link: "A", article: story.id, photo: story.photos[0].id), Fill(frame: whole.id, article: story.id)]
        guard let placedID = issue.place(folio, version: 1, on: 1, at: CGPoint(x: 100, y: 300), fills: fills) else {
            check("components: a component is placed on page 2", false, ""); return
        }

        // 1. the issue keeps a copy of the version it uses, and only that one
        check("placing a component copies its version into the issue", issue.componentVersions.count == 1
              && issue.componentVersions[0].id == folio.id && issue.componentVersions[0].versions.map(\.number) == [1], "\(issue.componentVersions.map { $0.versions.map(\.number) })")
        check("  the placed component resolves to it", issue.version(of: issue.layout!.pages[1].components[0])?.number == 1)

        // 2. what it draws
        let pages = composer.compose(issue)
        let cp = pages[1]
        func texts(_ cp: ComposedPage) -> [(String, CGRect, NSFont?)] {
            cp.ops.compactMap { if case let .text(s, r) = $0 { (s.string, r, s.length > 0 ? s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) } else { nil } }
        }
        let placedFrame = CGRect(x: 100, y: 300, width: 540, height: 560)
        check("a placed component is drawn at its frame", cp.componentFrames[placedID] == placedFrame, "\(String(describing: cp.componentFrames[placedID]))")
        let red = cp.ops.contains { if case let .fill(r, c) = $0 { r == CGRect(x: 100, y: 320, width: 540, height: 18) && abs(c.redComponent - HouseStyle.red.redComponent) < 0.01 && abs(c.greenComponent - HouseStyle.red.greenComponent) < 0.01 } else { false } }
        let rule = cp.ops.contains { if case let .line(a, b, w, _) = $0 { a == CGPoint(x: 100, y: 318) && b == CGPoint(x: 640, y: 318) && w == 0.5 } else { false } }
        let oval = cp.ops.contains { if case .path = $0 { true } else { false } }
        let art = cp.ops.contains { if case let .art(_, r) = $0 { r == CGRect(x: 600, y: 500, width: 30, height: 30) } else { false } }
        check("  its shapes, rule and art land where its boxes say", red && rule && oval && art, "fill \(red) rule \(rule) ellipse \(oval) art \(art)")
        let t = texts(cp)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        // an issue field sets on its frame's first baseline, aligned in its box as the frame says (phase 4)
        func on(_ r: CGRect, _ box: CGRect) -> Bool { abs(r.minY - box.minY) < 0.01 && r.minX >= box.minX - 0.01 && r.maxX <= box.maxX + 0.01 }
        check("  preset text and the date in the frame's own format", t.contains { $0.0 == "poly.rpi.edu" } && t.contains { $0.0 == df.string(from: issue.date) && on($0.1, CGRect(x: 300, y: 300, width: 200, height: 16)) && abs($0.1.midX - 400) < 1 })
        check("  the page number is this page's", t.contains { $0.0 == "2" && on($0.1, CGRect(x: 600, y: 300, width: 40, height: 16)) && abs($0.1.maxX - 640) < 0.01 })
        let desks = Set(issue.layout!.pages[1].stories.compactMap { b in issue.articles.first { $0.id == b.article }?.desk.rawValue } + [story.desk.rawValue])
        let deskDrawn = t.filter { $0.1 == CGRect(x: 500, y: 300, width: 100, height: 16) }.map(\.0)
        check("  the desk is named on a one-desk page and left empty on a mixed one", desks.count == 1 ? deskDrawn == [desks.first!] : deskDrawn.isEmpty, "page 2 desks \(desks.sorted()), drawn \(deskDrawn)")
        // a headline frame sets its lines as a block's headline (phase 7), drawn as a flow from the frame's corner
        let headFrame = CGRect(x: 100, y: 340, width: 300, height: 40)
        check("  a linked story fills its headline frame", SelfTest.headlineFlow(in: headFrame, cp.ops)?.text.trimmed.isEmpty == false,
              "want one at \(headFrame); flows: \(describeFlows(cp.ops))")
        let pic = cp.ops.contains { if case let .image(_, r, stroke, _) = $0 { r == CGRect(x: 420, y: 340, width: 200, height: 120) && stroke == 0 } else { false } }
        check("  and its picture, without the hairline the frame turned off", pic)
        check("  its caption too", story.photos[0].caption.trimmed.isEmpty || t.contains { $0.0.hasPrefix(story.photos[0].caption.trimmed) && $0.1.minY == 464 })

        // 3. body and whole-story frames set as blocks, in the component's columns, and the story jumps between them
        let results = cp.componentBlockResults[placedID] ?? [:]
        let bodyR = results[body.id], wholeR = results[whole.id]
        check("  a body frame sets the story's body as a block", bodyR.map { $0.used > 0 && $0.room > 0 } == true, "\(String(describing: bodyR))")
        check("  with no headline or byline of its own", !t.contains { $0.0 == story.plainHeadline && $0.1.minY == 390 } && bodyR?.byline == nil)
        check("  the story runs on from the body frame into the whole-story frame", (wholeR?.start ?? 0) == (bodyR?.end ?? -1) && (wholeR?.used ?? 0) > 0 && (bodyR?.end ?? 0) > 0,
              "body end \(bodyR?.end ?? -1), whole start \(wholeR?.start ?? -1)")
        check("  the whole-story frame carries the headline and byline", wholeR.map { $0.inkTop < $0.bottom && (story.author.trimmed.isEmpty || $0.byline != nil) } == true, "\(String(describing: wholeR))")
        check("  frames aren't story blocks for the canvas", cp.storyFrames.count == issue.layout!.pages[1].stories.count)
        let wholeCols = composer.componentBlocks(on: issue.layout!.pages[1], issue: issue, pageColumns: layout.columns, articles: Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        check("  a frame across both of the component's columns sets in two", wholeCols.first { $0.frame == whole.id }?.block.columns == 2 && wholeCols.first { $0.frame == body.id }?.block.columns == 1
              && wholeCols.first?.gutter == 20, "\(wholeCols.map { ($0.block.columns, $0.gutter) })")

        // 4. a story is jumped from a component on one page to one on another
        do {
            var two = issue
            var v = v1; v.elements = [.frame(Frame(type: .body, box: Box(x: 0, y: 0, w: 300, h: 120)))]
            v.number = 3
            let c = Component(name: "Jump", versions: [v]).with(id: UUID())
            let bodyID = v.frames[0].id
            _ = two.place(c, version: 3, on: 2, at: CGPoint(x: 36, y: 400), fills: [Fill(frame: bodyID, article: story.id)])
            let ps = composer.compose(two)
            let first = ps[1].componentBlockResults[placedID]?[whole.id]
            let second = ps[2].componentBlockResults.values.first?[bodyID]
            check("a story jumps from a component on page 2 to one on page 3", first?.jumped == true && first?.jumpTo == 3 && second?.continuedFrom == 2 && second?.start == first?.end,
                  "jumpTo \(String(describing: first?.jumpTo)) from \(String(describing: second?.continuedFrom))")
        }

        // 5. stories wrap around a placed component as they do a picture
        do {
            let pageStories = issue.layout!.pages[1].stories
            if let b = pageStories.first(where: { $0.frame.rect.intersects(placedFrame) }), let r = cp.blockResults[b.id] {
                var without = issue
                without.layout!.pages[1].components = []
                let r0 = composer.compose(without)[1].blockResults[b.id]
                check("a story under a component keeps clear of it", (r0?.room ?? 0) > r.room, "room \(r0?.room ?? 0) → \(r.room)")
            } else {
                check("a story under a component keeps clear of it", false, "no story under the component on page 2")
            }
        }

        // 6. a resized placement scales the boxes, not the type
        do {
            var wide = issue
            wide.layout!.pages[1].components[0].frame = Box(x: 100, y: 300, w: 1080, h: 560)
            let w = composer.compose(wide)[1]
            let tw = texts(w)
            // the page number box scales to (1100, 300, 80, 16); the number sets on its first baseline, right-aligned (phase 4)
            let num = tw.first { $0.0 == "2" && on($0.1, CGRect(x: 1100, y: 300, width: 80, height: 16)) }
            let wideFill = w.ops.contains { if case let .fill(r, _) = $0 { r.width == 1080 } else { false } }
            check("resizing a placed component moves its boxes and keeps its type size",
                  num.map { abs($0.1.maxX - 1180) < 0.01 && $0.2?.pointSize == 12 } == true && wideFill,
                  "page number \(num.map { "\($0.1) \($0.2?.pointSize ?? 0) pt" } ?? "not in its box: \(tw.filter { $0.0 == "2" }.map { "\($0.1)" })"), red box 1080 wide \(wideFill)")
        }

        // 7. pages without components draw exactly as before
        check("a page with no component on it draws as before", pages[0].ops.count == before[0], "page 1 ops \(before[0]) → \(pages[0].ops.count)")

        // 8. saved and read back: plain JSON, and inside a .typeset file
        do {
            let d = try! IssueStore.encoder().encode(issue)
            let back = try? IssueStore.decoder().decode(Issue.self, from: d)
            check("an issue with a component saves and reloads the same", back?.componentVersions == issue.componentVersions && back?.layout?.pages[1].components == issue.layout?.pages[1].components)
            let file = data.appendingPathComponent("components.typeset")
            let media = data.appendingPathComponent("ComponentsMedia", isDirectory: true)
            try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let round = (try? IssueFile.write(issue, to: file)).flatMap { _ in try? IssueFile.read(file, mediaDir: media) }
            check("  inside a .typeset file too", round?.componentVersions == issue.componentVersions && round?.layout?.pages[1].components == issue.layout?.pages[1].components)

            // an element this build can't read is dropped on its own; a component that can't be read is dropped on its own
            var json = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
            var comps = json["componentVersions"] as! [[String: Any]]
            var vers = comps[0]["versions"] as! [[String: Any]]
            var els = vers[0]["elements"] as! [[String: Any]]
            let n = els.count
            els.append(["kind": "hologram", "box": ["x": 0, "y": 0, "w": 1, "h": 1]])
            els.append(["kind": "frame", "type": "footnote", "box": ["x": 0, "y": 0, "w": 1, "h": 1]])
            vers[0]["elements"] = els
            comps[0]["versions"] = vers
            comps.append(["id": "not a uuid", "name": "Broken", "versions": "none"])
            json["componentVersions"] = comps
            var lay = json["layout"] as! [String: Any]
            var pgs = lay["pages"] as! [[String: Any]]
            var placed = pgs[1]["components"] as! [[String: Any]]
            placed.append(["component": folio.id.uuidString, "version": 1])      // no frame: unreadable
            pgs[1]["components"] = placed
            lay["pages"] = pgs
            json["layout"] = lay
            let lenient = try? IssueStore.decoder().decode(Issue.self, from: try! JSONSerialization.data(withJSONObject: json))
            check("an element or component that can't be read is dropped on its own",
                  lenient?.componentVersions.count == 1 && lenient?.componentVersions[0].versions[0].elements.count == n && lenient?.layout?.pages[1].components.count == 1,
                  "components \(lenient?.componentVersions.count ?? -1), elements \(lenient?.componentVersions.first?.versions.first?.elements.count ?? -1), placed \(lenient?.layout?.pages[1].components.count ?? -1)")
            check("  a placed component whose version is missing draws nothing and breaks nothing", {
                var gone = issue; gone.componentVersions = []
                let p = composer.compose(gone)[1]
                return p.componentFrames.isEmpty && p.componentBlockResults.isEmpty
            }())
        }

        // 9. an issue saved before components reads with none, and the seed issue has none
        do {
            let seed = IssueStore.load(from: Bundle.main.url(forResource: "seed-issue", withExtension: "json")!)
            check("an older issue opens with no components", seed?.componentVersions.isEmpty == true && seed?.layout?.pages.allSatisfy { $0.components.isEmpty } != false)
            var pruned = issue
            pruned.layout!.pages[1].components = []
            pruned.pruneComponentVersions()
            check("versions no page uses are pruned", pruned.componentVersions.isEmpty)
        }

        fixes(check, issue: issue, story: story, placedID: placedID, composer: composer)
    }

    /// Phase 3 review fixes: the page cache, the desk, re-planning a page, and components on components.
    @MainActor
    private static func fixes(_ check: (String, Bool, String) -> Void, issue: Issue, story: Article, placedID: PlacedComponent.ID, composer: Composer) {
        let cols = issue.layout!.columns
        func texts(_ cp: ComposedPage) -> [(String, CGRect)] {
            cp.ops.compactMap { if case let .text(s, r) = $0 { (s.string, r) } else { nil } }
        }
        // a component showing only a story's headline, on a page none of that story's blocks are on
        let head = Frame(type: .headline, box: Box(x: 0, y: 20, w: 400, h: 60), link: "A")
        let desk = Frame(type: .desk, box: Box(x: 0, y: 0, w: 200, h: 16))
        let teaser = Component(name: "Teaser", versions: [ComponentVersion(width: 400, height: 80, elements: [.frame(desk), .frame(head)])])
        // nothing else on page 3 shows it, and preferably not a News story, so the desk test can't pass by default
        let p3 = issue.layout!.pages[2]
        guard let other = issue.articles.filter({ a in a.id != story.id && !a.plainHeadline.trimmed.isEmpty
            && !p3.stories.contains { $0.article == a.id } && !p3.insets.contains { $0.article == a.id } && !p3.components.contains { c in c.fills.contains { $0.article == a.id } } })
            .min(by: { ($0.desk == .news ? 1 : 0) < ($1.desk == .news ? 1 : 0) }) else {
            check("components fixes: a second story to show in a headline frame", false, ""); return
        }
        var t = issue
        let headRect = CGRect(x: 100, y: 120, width: 400, height: 60)
        _ = t.place(teaser, version: 1, on: 2, at: CGPoint(x: 100, y: 100), fills: [Fill(link: "A", article: other.id)])
        let first = SelfTest.headlineFlow(in: headRect, composer.compose(t)[2].ops)?.text
        if let i = t.articles.firstIndex(where: { $0.id == other.id }) { t.articles[i].headline = "Changed In The Stories Screen" }
        let secondOps = composer.compose(t)[2].ops
        let second = SelfTest.headlineFlow(in: headRect, secondOps)?.text
        if second == nil { check("  (flows on page 3)", false, describeFlows(secondOps)) }
        check("editing a story shown only in a component's headline frame redraws the page", first != nil && second != first && second?.lowercased().contains("stories screen") == true,
              "\(first ?? "nil") → \(second ?? "nil")")

        // the desk counts the stories in a component's frames: alone on a page, they name it
        var alone = t
        alone.layout!.pages[2].stories = []; alone.layout!.pages[2].insets = []
        let deskRect = CGRect(x: 100, y: 100, width: 200, height: 16)
        let drawn = texts(composer.compose(alone)[2]).filter { abs($0.1.minY - deskRect.minY) < 0.01 && $0.1.minX == deskRect.minX && $0.1.maxX <= deskRect.maxX }.map(\.0)
        check("a page whose only story is in a component's headline frame takes that story's desk", drawn == [other.desk.rawValue], "drawn \(drawn), desk \(other.desk.rawValue)")

        // re-planning a page keeps its components, their fills, and its own pictures clear of them
        do {
            // the test folio, shrunk into the page's lower right corner, leaves the page room to re-plan
            var small = issue
            small.layout!.pages[1].components[0].frame = Box(x: 600, y: HouseStyle.bottom - 120, w: 160, h: 120)
            let page = small.layout!.pages[1]
            let composed = composer.compose(small)
            let gen = LayoutGenerator(issue: small, composer: composer, seed: 7, columns: cols)
            if let p = gen.reshuffle(page, number: 2, incoming: composed[1].incoming, continuedFrom: [:]) {
                let wrap = Composer.wrap(page.components[0].frame.rect)
                let kept = Set(page.insets.map(\.id))
                let clear = p.insets.filter { !kept.contains($0.id) }.allSatisfy { !$0.frame.rect.intersects(wrap) }
                check("shuffling a page keeps its placed components and their fills", p.components == page.components && p.components.first?.id == placedID,
                      "kept \(p.components.map(\.frame.rect)) of \(page.components.map(\.frame.rect))")
                check("  and plans its own pictures clear of them", clear, p.insets.filter { !kept.contains($0.id) }.map { "\($0.frame.rect) vs \(wrap) frame \(page.components[0].frame.rect)" }.joined(separator: "; "))
            } else {
                check("shuffling a page keeps its placed components and their fills", false,
                      "the page didn't re-plan: \(page.stories.count) stories, top \(LayoutGenerator.top(of: page)), components \(page.components.map(\.frame.rect))")
            }
        }

        // a component with a body frame on top of a larger one (a background panel) still sets its story; the
        // panel on top of it covers it
        do {
            var stack = issue
            stack.layout!.pages[1].components = []
            stack.layout!.pages[1].stories = []; stack.layout!.pages[1].insets = []
            let panel = Component(name: "Panel", versions: [ComponentVersion(width: 700, height: 900, elements: [
                .rect(ShapeElement(box: Box(x: 0, y: 0, w: 700, h: 900), fill: Paint(r: 0.95, g: 0.95, b: 0.9)))])])
            let bodyFrame = Frame(type: .body, box: Box(x: 0, y: 0, w: 300, h: 300))
            let small = Component(name: "Box", versions: [ComponentVersion(width: 300, height: 300, columns: 1, elements: [.frame(bodyFrame)])])
            func used(panelFirst: Bool) -> Int {
                var s = stack
                if panelFirst { _ = s.place(panel, version: 1, on: 1, at: CGPoint(x: 50, y: 100)) }
                let id = s.place(small, version: 1, on: 1, at: CGPoint(x: 150, y: 300), fills: [Fill(frame: bodyFrame.id, article: story.id)])!
                if !panelFirst { _ = s.place(panel, version: 1, on: 1, at: CGPoint(x: 50, y: 100)) }
                return composer.compose(s)[1].componentBlockResults[id]?[bodyFrame.id]?.used ?? -1
            }
            let over = used(panelFirst: true), under = used(panelFirst: false)
            check("a component's body sets on top of a larger component beneath it", over > 0 && under <= 0, "on top \(over), underneath \(under)")
        }
    }
}
