import AppKit

/// Phase 7 checks for Make Component…: a selection of blocks, pictures, a pull quote and an ad becomes a component
/// whose frames sit where the items drew their parts, saved empty and placed filled, so the page sets as it did
/// (the drawn text runs and picture rects are compared before and after); two stories take two link letters; a
/// story that jumps to or continues from another page keeps its jump line and "Continued from"; a selection of
/// nothing but pictures; the in-place editor opens on it; one undo step puts everything back. Built on two cleared
/// inside pages of the seed issue; everything is put back.
extension SelfTest {
    /// Every piece of type on a composed page: its text and where it starts. A `.text` op is the string at its
    /// rect's corner; a `.flow` op (a headline or a column of body) is the text its container holds, at the
    /// container's first line.
    static func textRuns(_ cp: ComposedPage) -> [(text: String, at: CGPoint)] {
        var out: [(text: String, at: CGPoint)] = []
        for op in cp.ops {
            switch op {
            case .text(let s, let r):
                if s.length > 0 { out.append((s.string, CGPoint(x: r.minX, y: r.minY))) }
            case .flow(let lm, let tc, let origin):
                let glyphs = lm.glyphRange(for: tc)
                guard glyphs.length > 0, let storage = lm.textStorage else { continue }
                let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let line = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                out.append(((storage.string as NSString).substring(with: chars), CGPoint(x: origin.x + line.minX, y: origin.y + line.minY)))
            default: continue
            }
        }
        return out
    }

    /// Every picture on a composed page (drawn, fitted or missing), by its rect.
    static func pictureRects(_ cp: ComposedPage) -> [CGRect] {
        cp.ops.compactMap {
            switch $0 {
            case .image(_, let r, _, _), .fitted(_, let r), .missing(let r): return r
            default: return nil
            }
        }
    }

    /// The runs in `before` that `after` doesn't draw within a point of the same place, and the ones `after` adds.
    static func runDifferences(_ before: [(text: String, at: CGPoint)], _ after: [(text: String, at: CGPoint)], tolerance: CGFloat = 1) -> [String] {
        var left = after
        var out: [String] = []
        for b in before {
            if let k = left.firstIndex(where: { $0.text == b.text && abs($0.at.x - b.at.x) <= tolerance && abs($0.at.y - b.at.y) <= tolerance }) {
                left.remove(at: k)
            } else {
                let near = after.first { $0.text == b.text }
                out.append("missing “\(b.text.prefix(24))” at \(Int(b.at.x)),\(Int(b.at.y))" + (near.map { " (drawn at \(Int($0.at.x)),\(Int($0.at.y)))" } ?? ""))
            }
        }
        for a in left { out.append("added “\(a.text.prefix(24))” at \(Int(a.at.x)),\(Int(a.at.y))") }
        return out
    }

    static func rectDifferences(_ before: [CGRect], _ after: [CGRect], tolerance: CGFloat = 0.5) -> [String] {
        var left = after
        var out: [String] = []
        func s(_ r: CGRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height) }
        for b in before {
            if let k = left.firstIndex(where: { abs($0.minX - b.minX) <= tolerance && abs($0.minY - b.minY) <= tolerance && abs($0.width - b.width) <= tolerance && abs($0.height - b.height) <= tolerance }) {
                left.remove(at: k)
            } else { out.append("missing picture \(s(b))") }
        }
        for a in left { out.append("added picture \(s(a))") }
        return out
    }

    @MainActor
    static func makeComponentChecks(_ store: IssueStore, data: URL, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        guard let layout = store.issue.layout, layout.pages.count >= 3 else { check("make: a generated issue with three pages", false); return }
        let articles = store.issue.articles
        guard let s0 = articles.first(where: { !$0.photos.isEmpty && !$0.author.trimmed.isEmpty && !$0.photos[0].caption.trimmed.isEmpty }),
              let sq = articles.first(where: { !$0.pullQuote.trimmed.isEmpty && $0.id != s0.id }),
              let s2 = articles.first(where: { $0.photos.count >= 2 && $0.id != s0.id }),
              let sj = articles.filter({ $0.id != s0.id && $0.id != sq.id && $0.id != s2.id }).max(by: { $0.body.count < $1.body.count })
        else { check("make: stories with a photo, a pull quote, two photos and a long body", false); return }

        let saved = store.issue, savedZoom = store.zoom, savedUndo = store.undoManager
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.zoom = 1
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        var ad: Extra.ID?
        defer {
            store.closeInPlace()
            step { store.pointerCancelled() }
            if let ad { step { store.removeExtra(ad) } }      // it registers undo: in a group of the test's own manager
            store.issue = saved; store.zoom = savedZoom; store.undoManager = savedUndo; store.select([])
        }
        let pg = layout.pages.count - 1, pg2 = layout.pages.count - 2
        let g = store.grid
        // page pg: A (s0, two columns, its photo on it) beside B (the pull-quote story, its quote on it); an ad
        // under A; J2 under them, continuing the long story from J1 on page pg2. A story reads in page order, so
        // its first block must be on the earlier page (pg2)
        let A = StoryBlock(article: s0.id, frame: Box(x: g.x(0), y: 120, w: g.span(2), h: 320), columns: 2, headlineSize: HouseStyle.headlineSize(columns: 2))
        let photo = Inset(kind: .photo, article: s0.id, photo: s0.photos[0].id, frame: Box(x: g.x(1), y: 200, w: g.colWidth, h: 90))
        let B = StoryBlock(article: sq.id, frame: Box(x: g.x(2), y: 120, w: g.colWidth, h: 320), columns: 1, headlineSize: HouseStyle.headlineSize(columns: 1))
        let quote = Inset(kind: .pullQuote, article: sq.id, frame: Box(x: g.x(2), y: 300, w: g.colWidth, h: 60))
        let J1 = StoryBlock(article: sj.id, frame: Box(x: g.x(2), y: 620, w: g.colWidth, h: 200), columns: 1, headlineSize: HouseStyle.headlineSize(columns: 1))
        let J2 = StoryBlock(article: sj.id, frame: Box(x: g.x(0), y: 680, w: g.span(2), h: 480), columns: 2, headlineSize: HouseStyle.headlineSize(columns: 2))
        // page pg2: J1, and two photos of one story with nothing under them
        let p2a = Inset(kind: .photo, article: s2.id, photo: s2.photos[0].id, frame: Box(x: g.x(2), y: 120, w: g.colWidth, h: 100))
        let p2b = Inset(kind: .photo, article: s2.id, photo: s2.photos[1].id, frame: Box(x: g.x(2), y: 400, w: g.colWidth, h: 100))
        step { store.edit("Stage") {
            for i in [pg, pg2] {
                store.issue.layout!.pages[i].stories = []
                store.issue.layout!.pages[i].insets = []
                store.issue.layout!.pages[i].components = []
            }
            // the staged stories start on these pages: a block of one left elsewhere (the seed lays them all out)
            // would come first in reading order, so A, B or J1 would set as its continuation, or nothing at all
            let staged: Set<Article.ID> = [s0.id, sq.id, sj.id]
            for i in store.issue.layout!.pages.indices { store.issue.layout!.pages[i].stories.removeAll { staged.contains($0.article) } }
            store.issue.layout!.pages[pg].stories = [A, B, J2]
            store.issue.layout!.pages[pg].insets = [photo, quote]
            store.issue.layout!.pages[pg2].stories = [J1]
            store.issue.layout!.pages[pg2].insets = [p2a, p2b]
        } }
        let jpg = Bundle.main.resourceURL!.appendingPathComponent("SeedMedia/p2-engineers-rallying.jpg")
        var adInset: Inset.ID?
        if let e = store.addExtra(.ad, file: jpg), let k = store.issue.extras.firstIndex(where: { $0.id == e }) {
            ad = e
            store.issue.extras[k].columns = 2
            store.issue.extras[k].height = 100
            adInset = step { store.placeExtra(e, on: pg, at: CGPoint(x: g.x(0), y: 480)) }
        }
        undo.removeAllActions()
        store.select([])
        guard let adInset else { check("make: an ad placed under the block", false); return }

        func frames(_ id: PlacedComponent.ID) -> [Frame] { store.placedComponent(id).flatMap { store.issue.version(of: $0.placed) }?.frames ?? [] }
        func types(_ fs: [Frame], _ link: String?) -> Set<FrameType> { Set(fs.filter { $0.link == link }.map(\.type)) }
        func pageOps(_ i: Int) -> ([(text: String, at: CGPoint)], [CGRect]) { let cp = store.displayPages[i]; return (textRuns(cp), pictureRects(cp)) }
        func same(_ before: ([(text: String, at: CGPoint)], [CGRect]), _ after: ([(text: String, at: CGPoint)], [CGRect])) -> [String] {
            runDifferences(before.0, after.0) + rectDifferences(before.1, after.1)
        }
        func rs(_ r: CGRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height) }

        // MARK: two stories, a photo, a pull quote and an ad

        let before = pageOps(pg), before2 = pageOps(pg2)
        check("make: the staged page draws its stories (\(before.0.count) runs, \(before.1.count) pictures)", before.0.count > 6 && before.1.count == 2)
        let sel1: Set<LayoutSelection> = [.block(A.id), .block(B.id), .inset(photo.id), .inset(quote.id), .inset(adInset)]
        let made = step { store.makeComponent(from: sel1, name: "Lead Package") }
        guard let made, let (madePage, placed) = store.placedComponent(made) else { check("make: Make Component returns a placed component", false, "nil"); return }
        let fs = frames(made)
        let bounds = A.frame.rect.union(B.frame.rect).union(store.displayPages[pg].componentFrames[made] ?? .zero)
        check("make: the component is placed on the page, over the box round the items", madePage == pg && abs(placed.frame.rect.minX - g.x(0)) < 0.01 && abs(placed.frame.rect.minY - 120) < 0.01
              && abs(placed.frame.rect.maxX - (g.x(2) + g.colWidth)) < 0.01 && placed.frame.rect.maxY > 570, rs(placed.frame.rect) + " vs " + rs(bounds))
        check("  it takes the page's columns: the three it lies across", store.issue.version(of: placed)?.columns == 3, "\(store.issue.version(of: placed)?.columns ?? -1)")
        check("  the items came off the page; the block under them stayed",
              store.page(of: .block(A.id)) == nil && store.page(of: .block(B.id)) == nil && store.page(of: .inset(photo.id)) == nil && store.page(of: .inset(quote.id)) == nil
              && store.page(of: .inset(adInset)) == nil && store.page(of: .block(J2.id)) == pg && store.issue.layout!.pages[pg].components.count == 1)
        var wantA: Set<FrameType> = [.headline, .author, .body, .image, .caption]
        if !s0.authorTitle.trimmed.isEmpty { wantA.insert(.authorTitle) }
        if !s0.kicker.trimmed.isEmpty { wantA.insert(.kicker) }
        var wantB: Set<FrameType> = [.headline, .author, .body, .pullQuote]
        if !sq.authorTitle.trimmed.isEmpty { wantB.insert(.authorTitle) }
        if !sq.kicker.trimmed.isEmpty { wantB.insert(.kicker) }
        check("make: block A becomes headline, author, author title, body and (its photo) image and caption frames, linked A", types(fs, "A") == wantA, "\(types(fs, "A").map(\.rawValue).sorted())")
        check("  block B becomes headline, author, author title, body and (its quote) pull-quote frames, linked B", types(fs, "B") == wantB, "\(types(fs, "B").map(\.rawValue).sorted())")
        check("  the ad becomes an ad frame of its own, unlinked", types(fs, nil) == [.ad] && fs.count == wantA.count + wantB.count + 1, "\(types(fs, nil).map(\.rawValue).sorted()) of \(fs.count)")
        let fillA = placed.fills.first { $0.link == "A" }, fillB = placed.fills.first { $0.link == "B" }, fillAd = placed.fills.first { $0.frame == fs.first { $0.type == .ad }?.id }
        check("  the placement is filled: story A with its photo, story B, the ad; one fill per letter and one for the ad",
              fillA?.article == s0.id && fillA?.photo == s0.photos[0].id && fillB?.article == sq.id && fillAd?.extra == ad && placed.fills.count == 3, "\(placed.fills.count) fills")
        let kept = store.issue.componentVersions.first { $0.id == placed.component }
        check("  the issue keeps the component, v1, under its name; it's in the sidebar's catalogue",
              kept?.name == "Lead Package" && kept?.versions.map(\.number) == [1] && store.catalogComponent(placed.component) != nil && placed.version == 1 && placed.custom == nil)
        check("  the saved version's frames are empty: elements are frames alone, nothing filled in them",
              kept?.version(1)?.elements.allSatisfy { $0.frame != nil } == true && kept?.version(1)?.frames.count == fs.count)
        // where the frames sit: the body frame starts where the block's text started, the image where the picture was
        let bodyA = fs.first { $0.type == .body && $0.link == "A" }, imageA = fs.first { $0.type == .image }
        let bodyARect = bodyA.map { CGRect(x: placed.frame.x + $0.box.x, y: placed.frame.y + $0.box.y, width: $0.box.w, height: $0.box.h) }
        check("  A's body frame is the block's width, from its text's start to its foot", bodyARect.map { abs($0.minX - A.frame.x) < 0.01 && abs($0.width - A.frame.w) < 0.01 && abs($0.maxY - A.frame.rect.maxY) < 0.01 && $0.minY > A.frame.y + 30 } == true, bodyARect.map(rs) ?? "none")
        check("  the image frame is the picture's rect", imageA.map { abs(placed.frame.x + $0.box.x - photo.frame.x) < 0.01 && abs(placed.frame.y + $0.box.y - photo.frame.y) < 0.01 && abs($0.box.w - photo.frame.w) < 0.01 && abs($0.box.h - photo.frame.h) < 0.01 } == true)
        // the page draws as it did
        let after = pageOps(pg)
        let diff = same(before, after)
        check("make: the page sets as it did: every text run and picture is drawn where it was (\(after.0.count) runs)", diff.isEmpty, diff.prefix(6).joined(separator: "; "))
        let results = store.displayPages[pg].componentBlockResults[made] ?? [:]
        let bodyLinks = Dictionary(fs.filter { $0.type == .body }.map { ($0.id, $0.link ?? "-") }, uniquingKeysWith: { a, _ in a })
        check("  the body frames are set as blocks of the component (two stories)", results.count == 2 && results.values.allSatisfy { $0.used > 0 && $0.start == 0 },
              results.map { "\(bodyLinks[$0.key] ?? "?"): start \($0.value.start) end \($0.value.end)/\($0.value.total) used \($0.value.used) room \($0.value.room) from \(String(describing: $0.value.continuedFrom))" }.sorted().joined(separator: "; "))
        // the in-place editor
        check("make: the in-place editor opens on it, with the frames", store.inPlace?.placed == made && store.inPlace?.editor.draft.frames.count == fs.count && store.selectionSet.isEmpty)
        // one undo step
        check("  it is one undo step, named", undo.canUndo && undo.undoActionName == "Make Component", undo.undoActionName)
        undo.undo()
        store.followInPlace()
        check("  one undo puts the blocks, pictures and ad back and takes the component off; the editor closes",
              store.page(of: .block(A.id)) == pg && store.page(of: .block(B.id)) == pg && store.page(of: .inset(photo.id)) == pg && store.page(of: .inset(quote.id)) == pg
              && store.page(of: .inset(adInset)) == pg && store.placedComponent(made) == nil && store.inPlace == nil && !undo.canUndo)
        let back = same(before, pageOps(pg))
        check("  and the page draws as before", back.isEmpty, back.prefix(4).joined(separator: "; "))
        undo.redo()
        check("  redo makes it again", store.placedComponent(made) != nil && store.page(of: .block(A.id)) == nil)
        undo.undo()
        store.followInPlace()
        undo.removeAllActions()

        // MARK: a story that jumps to another page, and one that continues from another

        // J1 on page pj jumps to J2 on page pc (pages read in order: pj = pg2 comes before pc = pg)
        let pj = pg2, pc = pg
        let beforeJ = before2, beforeC = before
        func jr(_ r: Composer.BlockResult?) -> String {
            r.map { "start \($0.start) end \($0.end) jumped \($0.jumped) jumpTo \(String(describing: $0.jumpTo)) from \(String(describing: $0.continuedFrom))" } ?? "no result"
        }
        let jumpBefore = store.displayPages[pj].blockResults[J1.id], contBefore = store.displayPages[pc].blockResults[J2.id]
        check("make: staged a story that jumps from page \(pj + 1) to page \(pc + 1)", jumpBefore?.jumpTo == pc + 1 && jumpBefore?.start == 0 && contBefore?.continuedFrom == pj + 1,
              "J1 \(jr(jumpBefore)); J2 \(jr(contBefore))")
        let madeJ = step { store.makeComponent(from: [.block(J1.id)], name: "Jumper") }
        if let madeJ, let bodyJ = frames(madeJ).first(where: { $0.type == .body }) {
            let r = store.displayPages[pj].componentBlockResults[madeJ]?[bodyJ.id]
            let cont = store.displayPages[pc].blockResults[J2.id]
            check("  the first block made into frames: its body frame still jumps to page \(pc + 1)", r?.jumped == true && r?.jumpTo == pc + 1 && r?.start == 0, jr(r))
            check("  the block on the next page still continues from page \(pj + 1), from where the frame left off",
                  cont?.continuedFrom == pj + 1 && cont?.start == r?.end && r?.end == jumpBefore?.end, "frame \(jr(r)); J2 \(jr(cont)); J1 was \(jr(jumpBefore))")
            let d1 = same(beforeJ, pageOps(pj)), d2 = same(beforeC, pageOps(pc))
            check("  both pages draw as they did", d1.isEmpty && d2.isEmpty, (d1 + d2).prefix(6).joined(separator: "; "))
            undo.undo(); store.followInPlace()
            check("  one undo puts the block back", store.page(of: .block(J1.id)) == pj && store.placedComponent(madeJ) == nil && !undo.canUndo)
        } else { check("make: a component from the jumping block, with a body frame", false) }
        undo.removeAllActions()
        let madeC = step { store.makeComponent(from: [.block(J2.id)], name: "Continued") }
        if let madeC, let bodyC = frames(madeC).first(where: { $0.type == .body }) {
            let r = store.displayPages[pc].componentBlockResults[madeC]?[bodyC.id]
            check("  the continuation made into frames: its body frame keeps “Continued from Page \(pj + 1)”", r?.continuedFrom == pj + 1 && r?.start == jumpBefore?.end,
                  "frame \(jr(r)); J1 was \(jr(jumpBefore))")
            check("  the first block still jumps to it", store.displayPages[pj].blockResults[J1.id]?.jumpTo == pc + 1, jr(store.displayPages[pj].blockResults[J1.id]))
            let d2 = same(beforeC, pageOps(pc))
            let contLine = pageOps(pc).0.contains { $0.text.hasPrefix("Continued from Page \(pj + 1)") }
            check("  the continuation page draws as it did, “Continued from” included", d2.isEmpty && contLine, "line drawn \(contLine); " + d2.prefix(6).joined(separator: "; "))
            check("  on page \(pc + 1) the frames are headline, author, author title and body (the continuation draws them too)", types(frames(madeC), "A").isSuperset(of: [.headline, .body]),
                  "\(types(frames(madeC), "A").map(\.rawValue).sorted())")
            undo.undo(); store.followInPlace()
            check("  one undo puts it back", store.page(of: .block(J2.id)) == pc && !undo.canUndo)
        } else { check("make: a component from the continuation block, with a body frame", false) }
        undo.removeAllActions()

        // MARK: nothing but pictures

        let picsBefore = pageOps(pg2)
        let madeP = step { store.makeComponent(from: [.inset(p2a.id), .inset(p2b.id)], name: "Pictures") }
        if let madeP, let (_, pp) = store.placedComponent(madeP) {
            let fp = frames(madeP)
            check("make: two photos become two image frames and their captions, each with its own fill, no story letter",
                  fp.filter { $0.type == .image }.count == 2 && fp.filter { $0.type == .caption }.count == 2 && fp.allSatisfy { $0.link == nil }
                  && pp.fills.count == 4 && pp.fills.allSatisfy { $0.frame != nil && $0.article == s2.id } && Set(pp.fills.compactMap(\.photo)) == [s2.photos[0].id, s2.photos[1].id],
                  "\(fp.map(\.type.rawValue)) · \(pp.fills.count) fills")
            check("  the component is the box round both, one column wide", abs(pp.frame.rect.minX - g.x(2)) < 0.01 && abs(pp.frame.rect.minY - 120) < 0.01 && pp.frame.rect.maxY > 500 && store.issue.version(of: pp)?.columns == 1, rs(pp.frame.rect))
            let d = same(picsBefore, pageOps(pg2))
            check("  the page draws as it did", d.isEmpty, d.prefix(6).joined(separator: "; "))
            check("  no body frame: nothing is set as a block", (store.displayPages[pg2].componentBlockResults[madeP] ?? [:]).isEmpty)
            undo.undo(); store.followInPlace()
            check("  one undo puts both photos back", store.page(of: .inset(p2a.id)) == pg2 && store.page(of: .inset(p2b.id)) == pg2 && store.placedComponent(madeP) == nil)
        } else { check("make: a component from two photos", false) }
        undo.removeAllActions()

        // MARK: a block carries the pictures of its story lying on it, even when they aren't selected

        let madeCarry = step { store.makeComponent(from: [.block(A.id), .block(B.id)], name: "Carried") }
        if let madeCarry {
            let fc = frames(madeCarry)
            check("make: a selected block takes its story's photo and pull quote with it, as a move does",
                  fc.contains { $0.type == .image && $0.link == "A" } && fc.contains { $0.type == .pullQuote && $0.link == "B" } && store.page(of: .inset(photo.id)) == nil && store.page(of: .inset(quote.id)) == nil
                  && store.page(of: .inset(adInset)) == pg)
            undo.undo(); store.followInPlace()
        } else { check("make: a component from two blocks", false) }
        undo.removeAllActions()
        check("make: nothing that can become a frame makes nothing", step { store.makeComponent(from: [], name: "Empty") } == nil && !undo.canUndo)
        check("  story letters run A, B… then AA", IssueStore.storyLetter(0) == "A" && IssueStore.storyLetter(25) == "Z" && IssueStore.storyLetter(26) == "AA")
    }
}
