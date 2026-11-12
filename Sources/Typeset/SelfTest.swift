import AppKit
import UniformTypeIdentifiers

/// `GALLEY_DATA_DIR=<scratch> Typeset --selftest`: checks for bugs the code review found, run headlessly against a
/// scratch copy of the data. Prints one line per check and exits non-zero if any fail.
enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["GALLEY_DATA_DIR"] else {
            FileHandle.standardError.write("set GALLEY_DATA_DIR to a scratch folder\n".data(using: .utf8)!)
            return 1
        }
        // the checks are written against a real issue and its pictures, which aren't in the repository
        guard Bundle.main.url(forResource: "seed-issue", withExtension: "json") != nil,
              Bundle.main.resourceURL.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("SeedMedia").path) }) == true else {
            FileHandle.standardError.write("the self-tests need a seed issue: Resources/Private/seed-issue.json and Resources/Private/SeedMedia, bundled by ./build.sh\n".data(using: .utf8)!)
            return 2
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        FontLoader.registerBundledFonts()
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let data = URL(fileURLWithPath: dir)
        try? fm.removeItem(at: data.appendingPathComponent("issue.json"))

        // 1. an unreadable issue.json is kept aside, not overwritten, and reported
        try? "{ this is not json".write(to: IssueStore.saveURL, atomically: true, encoding: .utf8)
        do {
            let s = IssueStore()
            let kept = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasPrefix("issue-unreadable-") } ?? []
            check("unreadable issue is backed up and reported", !kept.isEmpty && s.loadProblem != nil, kept.first ?? "no backup")
            s.saveNow()
            for k in kept { try? fm.removeItem(at: data.appendingPathComponent(k)) }
        }

        // 2. lenient decoding: an unknown desk, a photo with no path, an older layout missing keys
        do {
            let seed = IssueStore.load(from: Bundle.main.url(forResource: "seed-issue", withExtension: "json")!)!
            var json = try! JSONSerialization.jsonObject(with: IssueStore.encoder().encode(seed)) as! [String: Any]
            var arts = json["articles"] as! [[String: Any]]
            arts[0]["desk"] = "Arts & Culture"
            var photos = arts[1]["photos"] as? [[String: Any]] ?? []
            photos.append(["caption": "no path"])
            arts[1]["photos"] = photos
            json["articles"] = arts
            let story = seed.articles[0].id.uuidString
            json["layout"] = ["columns": 3, "pages": [["stories": [["article": story, "frame": ["x": 36, "y": 78, "w": 729, "h": 600]]],
                                                        "insets": [["kind": "photo", "frame": ["x": 0, "y": 0, "w": 10, "h": 10]], ["kind": "bogus"]]]]]
            let d = try! JSONSerialization.data(withJSONObject: json)
            let issue = try? IssueStore.decoder().decode(Issue.self, from: d)
            check("issue with a strange desk, a broken photo and an older layout still loads", issue != nil)
            if let issue {
                check("  every story kept", issue.articles.count == seed.articles.count, "\(issue.articles.count) of \(seed.articles.count)")
                check("  unknown desk reads as News", issue.articles[0].desk == .news)
                check("  only the broken photo dropped", issue.articles[1].photos.count == seed.articles[1].photos.count)
                let p = issue.layout?.pages.first
                check("  older layout kept, missing keys defaulted", p?.stories.count == 1 && p?.isFront == false && p?.legacyTeasers == []
                      && p?.stories.first?.columns == 1, "pages \(issue.layout?.pages.count ?? 0)")
                check("  unreadable inset dropped, readable one kept", p?.insets.count == 1)
            }
        }

        // a store on the seed issue with a generated paper, for the edits below
        try? fm.removeItem(at: IssueStore.saveURL)
        let store = IssueStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.generate()

        // 3. a pending save is written when the app quits
        do {
            try? fm.removeItem(at: IssueStore.saveURL)
            store.issue.volume = "SELFTEST"
            store.scheduleSave()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            let saved = (try? String(contentsOf: IssueStore.saveURL, encoding: .utf8)) ?? ""
            check("edit made just before quitting is saved", saved.contains("SELFTEST"))
        }

        // 4. Shuffle Page keeps an ad placed on the page
        let jpg = Bundle.main.resourceURL!.appendingPathComponent("SeedMedia/p2-engineers-rallying.jpg")
        if let ad = store.addExtra(.ad, file: jpg), let page = store.issue.layout?.pages.indices.first(where: { !store.issue.layout!.pages[$0].isFront }) {
            _ = store.placeExtra(ad, on: page, at: CGPoint(x: 300, y: 1000))
            let before = store.issue.layout!.pages[page].insets.contains { $0.extra == ad }
            store.shufflePage(page)
            let after = store.issue.layout!.pages[page].insets.contains { $0.extra == ad }
            check("Shuffle Page keeps a placed ad", before && after, "placed \(before), after shuffle \(after)")

            // 5. deleting a placed ad, then undo, brings back the ad and where it was
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            undo.removeAllActions()
            store.removeExtra(ad)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let name = undo.undoActionName
            undo.undo()
            let back = store.issue.extras.contains { $0.id == ad } && store.issue.layout!.pages[page].insets.contains { $0.extra == ad }
            check("undo after deleting a placed ad restores it", back, "undo name '\(name)'")
            check("  undo is named for the ad", name == "Delete Ad", name)
        } else { check("Shuffle Page keeps a placed ad", false, "couldn't place an ad") }

        // 6. nudging a block at the page edge moves its pictures only as far as the block
        if let layout = store.issue.layout,
           let (pi, b) = layout.pages.enumerated().lazy.compactMap({ (i, p) -> (Int, StoryBlock)? in
               p.stories.first { b in p.insets.contains { $0.article == b.article } }.map { (i, $0) } }).first {
            let pinned = CGRect(x: HouseStyle.page.width - b.frame.w, y: b.frame.y, width: b.frame.w, height: b.frame.h)
            let shift = pinned.minX - b.frame.x
            store.edit("Test") {
                for i in store.insets(with: b, on: pi) { store.setInsetFrame(i.id, page: pi, frame: i.frame.rect.offsetBy(dx: shift, dy: 0)) }
                store.setBlockFrame(b.id, page: pi, frame: pinned)
            }
            let before = store.insets(with: store.block(b.id)!.block, on: pi).map(\.frame.x)
            store.canvasSelection = .block(b.id)
            store.nudge(dx: 10, dy: 0)
            let after = store.insets(with: store.block(b.id)!.block, on: pi).map(\.frame.x)
            check("nudging a block at the page edge leaves its pictures in place", before == after && !before.isEmpty, "\(before) → \(after)")
        }

        // 7. a literal asterisk survives, and bold-italic next to italic reads back right
        do {
            let att = NSMutableAttributedString(string: "N*SYNC and *Correction", attributes: Markup.baseAttributes())
            let stored = Markup.paragraphs(from: att)
            let back = Markup.attributed(stored)
            let italic = (0..<back.length).contains { i in
                ((back.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic)) ?? false
            }
            check("a literal asterisk stays text", back.string == att.string && !italic, "stored \(stored)")
            let mixed = NSMutableAttributedString()
            mixed.append(NSAttributedString(string: "one", attributes: Markup.baseAttributes(italic: true, bold: true)))
            mixed.append(NSAttributedString(string: "two", attributes: Markup.baseAttributes(italic: true)))
            mixed.append(NSAttributedString(string: " three", attributes: Markup.baseAttributes()))
            mixed.append(NSAttributedString(string: "four", attributes: Markup.baseAttributes(italic: true)))
            mixed.append(NSAttributedString(string: "five", attributes: Markup.baseAttributes(italic: true, bold: true)))
            let s2 = Markup.paragraphs(from: mixed)
            let r2 = Markup.attributed(s2)
            func traits(_ a: NSAttributedString) -> [String] {
                (0..<a.length).map { i in
                    let t = (a.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    return "\(t.contains(.bold) ? "b" : "")\(t.contains(.italic) ? "i" : "")"
                }
            }
            check("bold-italic beside italic reads back the same", r2.string == mixed.string && traits(r2) == traits(mixed), "stored \(s2)")
            check("headline plain text drops markup and escapes", Markup.plain("A review of *The Stranger* \\*") == "A review of The Stranger *")
        }

        // 8 + 9. InDesign export: a HEIC picture goes as JPEG; a hyphen before an emoji doesn't crash
        do {
            let heic = data.appendingPathComponent("selftest.heic")
            if let src = CGImageSourceCreateWithURL(jpg as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let dest = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            }
            if let k = store.issue.articles.firstIndex(where: { a in store.issue.layout!.pages.contains { $0.stories.contains { $0.article == a.id } } }) {
                store.issue.articles[k].body[0] += " Vote-🗳 today."
                if let pid = store.issue.articles[k].photos.first?.id {
                    store.issue.articles[k].photos[0].path = heic.path
                    _ = store.placePhoto(pid, of: store.issue.articles[k].id, on: store.issue.layout!.pages.firstIndex { $0.stories.contains { $0.article == store.issue.articles[k].id } }!)
                }
            }
            let out = data.appendingPathComponent("selftest.idml")
            do {
                try IDMLExport.write(store.issue, pages: store.composedPages, composer: store.composer, to: out)
                // the spreads, read out of the package
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", out.path, "Spreads/*"]
                let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
                let names = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                check("export with a hyphen before an emoji doesn't crash", true)
                check("a HEIC picture is exported as JPEG", names.contains("selftest.jpg") && !names.contains("selftest.heic\""),
                      names.contains("selftest.jpg") ? "" : "no selftest.jpg in package")
            } catch { check("export with a hyphen before an emoji doesn't crash", false, "\(error)") }
        }

        // 10. a drag whose end is lost: the store's session closes itself
        do {
            Composer.pointerDown = { true }
            store.beginEdit()
            Composer.pointerDown = { false }
            _ = store.composedPages
            store.issue.volume = store.issue.volume + " "           // a change, so the composer looks again
            _ = store.composedPages
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("a lost drag end closes the edit session", !store.editingNow && !store.composer.deferFits)
            Composer.pointerDown = { NSEvent.pressedMouseButtons & 1 != 0 }
        }

        // 11. a labelled submission: fields read, unused ones dropped, desk from the kicker, Senior Reporters by default
        do {
            let sub = """
            Author: Marcus Delgado, Ava Brook
            Title: Rensselaer loses both games to Maine in back-to-back matches
            Kicker: Women’s Hockey
            Summary: Rensselaer women’s hockey struggled as they lost to the University of Maine 3-5 and 1-3.
            Article:
            \tRensselaer started the series against the University of Maine with a disappointing 3-5 loss, their seventh loss in their last eight games.
            In the first period, Rensselaer was called for a holding penalty early, which Maine capitalized on during the power play with a low shot.
            Both teams looked to gain control of the game moving into the next period, but it was Maine that took the lead first.

            After losing 3-5 on Friday, Rensselaer looked for a rematch against Maine the next day. While improvements were made, the result disappointed.
            \tThe series ended Maine's three game losing streak. Women's hockey will face off against Princeton this Friday and Quinnipiac on Saturday.
            """
            let paras = SmartPaste.plainParagraphs(sub).map(Markup.escape).map(SmartPaste.clean).filter { !$0.isEmpty }
            let a = SmartPaste.article(from: paras, staff: store.staff, desk: .news)
            check("a labelled submission is read field by field",
                  a?.headline == "Rensselaer loses both games to Maine in back-to-back matches"
                    && a?.author == "Marcus Delgado and Ava Brook" && a?.authorTitle == "Senior Reporters"
                    && a?.desk == .sports && a?.body.count == 5 && a?.body.first?.hasPrefix("Rensselaer started") == true
                    && a?.body.contains { $0.contains("Summary") || $0.contains("Kicker") } == false,
                  a.map { "\($0.desk.rawValue) | \($0.author) | \($0.authorTitle) | \($0.body.count) paras" } ?? "nil")
            let op = SmartPaste.article(from: ["Author: Ava Brook", "Kicker: Opinion", "Title: Fix the shuttle", "Article:", "The shuttle is late."],
                                        staff: store.staff, desk: .news)
            check("an opinion submission gets no default title", op?.desk == .opinion && op?.authorTitle == "",
                  op.map { "\($0.desk.rawValue) | \($0.authorTitle)" } ?? "nil")
            let solo = SmartPaste.article(from: ["Title: Union budget passes", "By: Ava Brook", "Body: The Senate voted."],
                                          staff: store.staff, desk: .news)
            check("a news submission defaults to Senior Reporter", solo?.authorTitle == "Senior Reporter" && solo?.desk == .news)
        }

        // 12. (GALLEY_WEB=1, needs the network) a story read from poly.rpi.edu, its photos downloaded once and reused
        if ProcessInfo.processInfo.environment["GALLEY_WEB"] == "1" {
            var story: PolyWeb.Story?, first: [Photo] = [], again: [Photo] = []
            var finished = false
            Task { @MainActor in
                story = try? await PolyWeb.story(slug: "pipe-bursts-in-cbis-ceiling-floods-lab-hallway")
                if let s = story {
                    first = await PolyWeb.download(s.photos, into: data, keeping: [])
                    again = await PolyWeb.download(s.photos, into: data, keeping: first)
                }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            check("a story is read from the website", story?.body.isEmpty == false && story?.author.isEmpty == false)
            check("its photos are downloaded with captions and credits",
                  !first.isEmpty && first.count == story?.photos.count && first.allSatisfy { fm.fileExists(atPath: $0.path) && !$0.credit.isEmpty },
                  "\(first.count) of \(story?.photos.count ?? 0)")
            check("photos already downloaded are kept, not fetched again", again.map(\.id) == first.map(\.id))
        }

        // 13. a .typeset file carries the issue and its pictures to another Mac
        do {
            var out = store.issue
            let pic = data.appendingPathComponent("export-test.png")
            try? Data(repeating: 7, count: 64).write(to: pic)
            if !out.articles.isEmpty { out.articles[0].photos.insert(Photo(path: pic.path, caption: "Test", credit: "A/B"), at: 0) }
            let file = data.appendingPathComponent("round-trip.typeset")
            let elsewhere = data.appendingPathComponent("OtherMac", isDirectory: true)
            try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            do {
                let missing = try IssueFile.write(out, to: file)
                try? fm.removeItem(at: pic)                               // the other Mac doesn't have the original
                let back = try IssueFile.read(file, mediaDir: elsewhere)
                let p = back.articles.first?.photos.first
                func pathless(_ i: Issue) -> [Article] { i.articles.map { a in var a = a; a.photos = a.photos.map { var p = $0; p.path = ""; return p }; return a } }
                check("a .typeset file round-trips the issue", missing.isEmpty && pathless(back) == pathless(out)
                        && back.layout == out.layout && back.extras.map(\.id) == out.extras.map(\.id))
                check("its pictures land in the other Mac's media folder",
                      p.map { $0.path.hasPrefix(elsewhere.path) && fm.fileExists(atPath: $0.path) && $0.caption == "Test" } == true
                        && back.articles.flatMap(\.photos).allSatisfy { $0.path.hasPrefix("seed:") || $0.path.hasPrefix(elsewhere.path) },
                      p?.path ?? "no photo")
            } catch { check("a .typeset file round-trips the issue", false, "\(error)") }
            check("something that isn't one is refused", (try? IssueFile.read(data.appendingPathComponent("issue.json"), mediaDir: elsewhere)) == nil)
        }

        // 14. bylines wrap, titles italicise inside headlines, dates hold together, kickers come through
        do {
            let lines = Composer.bylineLines("Casey Moore, Nikolaos Petridis and Jordan Hayes", width: 235)
            check("a long shared byline wraps inside its column", lines.count >= 2 && lines.joined(separator: " ") == "Casey Moore, Nikolaos Petridis and Jordan Hayes", lines.joined(separator: " | "))
            var a = Article(); a.author = "Casey Moore, Nikolaos Petridis and Jordan Hayes"
            check("a wrapped byline is taller by a line of names",
                  Composer.bylineHeight(a, width: 235) == HouseStyle.bylineHeight + CGFloat(lines.count - 1) * HouseStyle.bylineLeading
                    && Composer.bylineHeight(a, width: 729) == HouseStyle.bylineHeight)
            let head = Composer.headline(markup: "*Dungeon Crawler Carl* really is that good", size: 36)
            let italicRuns = (0..<head.length).filter { ((head.attribute(.font, at: $0, effectiveRange: nil) as? NSFont)?.fontName ?? "").contains("It") }.count
            check("a title inside a headline is set in the italic headline face", head.string == "Dungeon Crawler Carl really is that good" && italicRuns == 20, "\(italicRuns) italic characters")
            check("dates and times hold together", HouseStyle.keepTogether("Union College on October 30th. At 3 p.m. on Nov. 12, No. 7") == "Union College on October\u{00A0}30th. At 3\u{00A0}p.m. on Nov.\u{00A0}12, No.\u{00A0}7")
            let sub = SmartPaste.article(from: ["Author: Ava Brook", "Kicker: Women’s Hockey", "Title: Maine sweeps", "Article:", "Text."], staff: [], desk: .news)
            let bare = SmartPaste.article(from: ["Author: Ava Brook", "Kicker: Sports", "Title: Maine sweeps", "Article:", "Text."], staff: [], desk: .news)
            check("a kicker is kept, a bare desk name isn't", sub?.kicker == "Women’s Hockey" && bare?.kicker == "" && bare?.desk == .sports, "\(sub?.kicker ?? "nil") | \(bare?.kicker ?? "nil")")
            var k = Article(); k.headline = "Head"; k.kicker = "News Analysis"
            check("a kicker takes its band above the headline",
                  store.composer.headlineHeight(k, width: 400, size: 36) == store.composer.headlineHeight(a, width: 400, size: 36) + HouseStyle.kickerHeight
                    || { a.headline = "Head"; return store.composer.headlineHeight(k, width: 400, size: 36) == store.composer.headlineHeight(a, width: 400, size: 36) + HouseStyle.kickerHeight }())
            var page = PageLayout()
            let x = Article(), y = Article(), z = Article()
            page.stories = [StoryBlock(article: x.id, frame: Box(x: 36, y: 78, w: 729, h: 500), columns: 3, headlineSize: 36),
                            StoryBlock(article: y.id, frame: Box(x: 36, y: 598, w: 482, h: 600), columns: 2, headlineSize: 30),
                            StoryBlock(article: z.id, frame: Box(x: 530, y: 598, w: 235, h: 600), columns: 1, headlineSize: 28)]
            let rules = Composer.storyRules(page, around: [])
            check("hairlines run between stories that touch: one across the row, nearer the story above, one down the gutter",
                  rules.count == 2
                    && rules.contains { $0.from.y == $0.to.y && abs($0.from.y - 585) < 0.01 && $0.from.x == 36 && $0.to.x == 765 }
                    && rules.contains { $0.from.x == $0.to.x && abs($0.from.x - 524) < 0.01 },
                  rules.map { "(\($0.from.x),\($0.from.y))-(\($0.to.x),\($0.to.y))" }.joined(separator: " "))
        }

        // 15. a cropped picture shows the part its focus asks for
        do {
            let wide = CGSize(width: 400, height: 100), frame = CGSize(width: 100, height: 100)
            let left = ComposedPage.fillSource(image: wide, frame: frame, focus: CGPoint(x: 0, y: 0.5))
            let mid = ComposedPage.fillSource(image: wide, frame: frame, focus: CGPoint(x: 0.5, y: 0.5))
            let right = ComposedPage.fillSource(image: wide, frame: frame, focus: CGPoint(x: 1, y: 0.5))
            check("a crop slides with its focus", left.minX == 0 && mid.minX == 150 && right.minX == 300 && left.width == 100 && left.height == 100,
                  "\(left.minX) \(mid.minX) \(right.minX)")
            let tall = ComposedPage.fillSource(image: CGSize(width: 100, height: 300), frame: frame, focus: CGPoint(x: 0.3, y: 1))
            check("only the axis with something to hide moves", tall.minX == 0 && tall.minY == 200)
            var inset = Inset(kind: .photo, article: nil, photo: nil, extra: nil, frame: Box(x: 0, y: 0, w: 10, h: 10))
            inset.focus = CGPoint(x: 1.7, y: -2)
            let data = try? IssueStore.encoder().encode(inset)
            let back = data.flatMap { try? IssueStore.decoder().decode(Inset.self, from: $0) }
            check("a focus is kept within the picture and saved with the layout", inset.focus == CGPoint(x: 1, y: 0) && back?.focus == CGPoint(x: 1, y: 0))
        }

        // 16. pictures sit on the line grid: a line's clearance above, the text under the caption starting on a line
        do {
            let pitch = HouseStyle.leading, top: CGFloat = 100
            let r = Composer.onLineGrid(CGRect(x: 0, y: 150, width: 200, height: 133), caption: 14.8, bodyTop: top, pitch: pitch)
            func onGrid(_ v: CGFloat) -> Bool { let m = abs(v.truncatingRemainder(dividingBy: pitch)); return min(m, pitch - m) < 0.01 }
            let aboveOK = onGrid(r.minY - Composer.clearAbovePicture - top)
            let belowOK = onGrid(r.maxY + 14.8 + Composer.clearBelowPicture - top)
            check("a picture's top and the text under its caption sit on the line grid", aboveOK && belowOK && abs(r.height - 133) < pitch,
                  String(format: "top %.1f height %.1f", r.minY, r.height))
            let b = Composer.onLineGrid(CGRect(x: 0, y: 150, width: 200, height: 133), caption: 0, bodyTop: top, pitch: pitch, anchorBottom: true)
            check("anchored at the bottom, the bottom edge lands a clearance over a line",
                  onGrid(b.maxY + Composer.clearBelowPicture - top) && abs(b.height - 133) < 1.5 * pitch)
        }

        // 17. the band round a selected block yields to a neighbour under the pointer
        do {
            let a = Article(), b = Article()
            var page = PageLayout()
            let blockA = StoryBlock(article: a.id, frame: Box(x: 36, y: 78, w: 729, h: 400), columns: 3, headlineSize: 36)
            let blockB = StoryBlock(article: b.id, frame: Box(x: 36, y: 484, w: 729, h: 400), columns: 3, headlineSize: 36)
            page.stories = [blockA, blockB]
            let keep = (store.issue.layout, store.canvasSelection, store.zoom)
            store.issue.layout = IssueLayout(pages: [page], columns: 3)
            store.zoom = 1
            store.canvasSelection = .block(blockA.id)
            let inGap = store.zone(at: CGPoint(x: 300, y: 481), on: 0)
            let overB = store.zone(at: CGPoint(x: 300, y: 485), on: 0)
            let inside = store.zone(at: CGPoint(x: 300, y: 475), on: 0)
            check("a selected block's edge band yields where a neighbour lies under the pointer",
                  inGap == .s && overB == nil && inside == .s, "gap \(String(describing: inGap)) overB \(String(describing: overB)) inside \(String(describing: inside))")
            store.issue.layout = keep.0; store.canvasSelection = keep.1; store.zoom = keep.2
        }

        // 18. a kicker added to a laid-out story carries its picture down with the body, without generating again
        do {
            if let pi = store.issue.layout?.pages.indices.first(where: { i in
                   store.issue.layout!.pages[i].insets.contains { ins in ins.kind == .photo && store.issue.layout!.pages[i].stories.contains { $0.article == ins.article && $0.frame.rect.intersects(ins.frame.rect) } }
               }),
               let inset = store.issue.layout!.pages[pi].insets.first(where: { ins in ins.kind == .photo && store.issue.layout!.pages[pi].stories.contains { $0.article == ins.article && $0.frame.rect.intersects(ins.frame.rect) } }),
               let ai = store.issue.articles.firstIndex(where: { $0.id == inset.article }) {
                let was = store.issue.articles[ai]
                var now = was; now.kicker = "Self Test"
                let b = store.issue.layout!.pages[pi].stories.first { $0.article == was.id && $0.frame.rect.intersects(inset.frame.rect) }!
                let topBefore = store.composer.blockGeometry(was, frame: b.frame.rect, columns: b.columns, headlineSize: b.headlineSize, avoid: [], draw: false).bodyTop
                let startsBelow = inset.frame.rect.minY >= topBefore - 4
                store.issue.articles[ai] = now
                store.reflowArt(for: was, now: now)
                let after = store.issue.layout!.pages[pi].insets.first { $0.id == inset.id }!.frame.rect
                check("a kicker added to a laid-out story moves its picture down with the body",
                      !startsBelow || abs(after.minY - inset.frame.rect.minY - HouseStyle.kickerHeight) < 0.01,
                      String(format: "picture top %.1f → %.1f (kicker band %.0f)", inset.frame.rect.minY, after.minY, HouseStyle.kickerHeight))
                store.issue.articles[ai] = was
                store.reflowArt(for: now, now: was)
            } else {
                check("a kicker added to a laid-out story moves its picture down with the body", true, "no laid-out picture to try")
            }
        }

        files(check, data: data)
        components(check, store: store, data: data)                       // SelfTest+components.swift
        // 14. canvas interaction (phase 2): the hit test and the pointer state machine, in SelfTest+canvas.swift
        canvasChecks(store) { check($0, $1, $2) }
        canvasViewChecks(store) { check($0, $1, $2) }      // the page views, with mouse events: SelfTest+canvasViews.swift
        header(check, store: store, data: data)                           // SelfTest+header.swift (phase 4: Header, Folio, teasers)
        placingChecks(store, data: data) { check($0, $1, $2) }            // SelfTest+placing.swift (phase 5: components on the page)
        templates(check, store: store, data: data)                        // SelfTest+templates.swift (phase 8: templates)
        templateFixes(check, store: store, data: data)                    // SelfTest+templateFixes.swift (phase 8 review fixes)
        editorChecks(store, data: data) { check($0, $1, $2) }             // SelfTest+editor.swift (phase 6: the component editor)
        editorFixChecks { check($0, $1, $2) }                             // SelfTest+editorFixes.swift (phase 6 review fixes)
        inlineChecks(store, data: data) { check($0, $1, $2) }             // SelfTest+inline.swift (phase 7: multi-select, in place)
        makeComponentChecks(store, data: data) { check($0, $1, $2) }      // SelfTest+make.swift (phase 7: Make Component…)
        makeFixesChecks(store, data: data) { check($0, $1, $2) }          // SelfTest+makeFixes.swift (phase 7 review fixes)

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
