import AppKit

extension SelfTest {
    /// Phase 4: the Header and Folio as components. The generator places them and no longer teases stories 3–5;
    /// they draw per page (the date's format, the desk on a mixed page); teaser-headline frames set as a group;
    /// an issue saved before components gets them on open, filled with what it teased.
    @MainActor
    static func header(_ report: (String, Bool, String) -> Void, store: IssueStore, data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        let composer = store.composer
        // a paper generated afresh, so what the earlier checks moved doesn't count
        var issue = store.issue
        issue.generateLayout(composer: composer, seed: 1)
        guard let layout = issue.layout, layout.pages.count >= 3 else {
            check("header: the seed paper has three pages to try", false, "\(store.issue.layout?.pages.count ?? 0) pages"); return
        }
        typealias F = HouseStyle.Front
        func texts(_ cp: ComposedPage) -> [(String, CGRect)] {
            cp.ops.compactMap { if case let .text(s, r) = $0 { (s.string, r) } else { nil } }
        }
        let stories = issue.articles.filter { $0.body.contains { !$0.trimmed.isEmpty } }

        // 1. the generator places the Header on the front and the Folio inside, and teases nothing
        let front = layout.pages[0]
        let header = front.components.first { $0.component == BuiltInComponents.headerID }
        check("the generator puts the Header on the front page, at the house position",
              front.components.count == 1 && header?.frame.rect.origin == BuiltInComponents.headerOrigin && header?.version == 1,
              "\(front.components.map { "\(issue.componentName($0.component) ?? "?") at \($0.frame.rect.origin)" })")
        check("  and the Folio on every inside page", layout.pages.dropFirst().allSatisfy { p in
            p.components.count == 1 && p.components[0].component == BuiltInComponents.folioID && p.components[0].frame.rect.origin == BuiltInComponents.folioOrigin },
              "\(layout.pages.dropFirst().map { $0.components.map { issue.componentName($0.component) ?? "?" } })")
        check("  the issue keeps a copy of both", Set(issue.componentVersions.map(\.id)) == [BuiltInComponents.headerID, BuiltInComponents.folioID]
              && issue.componentVersions.allSatisfy { $0.versions.map(\.number) == [1] }, "\(issue.componentVersions.map { "\($0.name) \($0.versions.map(\.number))" })")
        check("  stories 3–5 are no longer teased: the Header's frames start empty", header?.fills.isEmpty == true && front.legacyTeasers.isEmpty, "\(header?.fills.count ?? -1) fills")
        let frontStories = Set(front.stories.map(\.article))
        check("  the front page's stories start under the Header, at the house lead top",
              front.stories.contains { $0.frame.y == F.leadTop } && frontStories == Set(stories.prefix(2).map(\.id)),
              "\(front.stories.map(\.frame.y))")
        check("  inside stories start at the house top, under the Folio",
              layout.pages.dropFirst().allSatisfy { p in p.stories.allSatisfy { $0.frame.y >= HouseStyle.insideTop - 0.01 } }
              && layout.pages.dropFirst().contains { p in p.stories.contains { $0.frame.y == HouseStyle.insideTop } },
              "\(layout.pages.dropFirst().map { $0.stories.map(\.frame.y).min() ?? -1 })")

        // 2. what the components draw on each page
        let pages = composer.compose(issue)
        let p1 = pages[0]
        let bar = p1.ops.contains { if case let .fill(r, c) = $0 { r == F.teaserBar && abs(c.redComponent - HouseStyle.red.redComponent) < 0.01 } else { false } }
        let plate = p1.ops.contains { if case let .art(_, r) = $0 { r == F.nameplate } else { false } }
        let df = DateFormatter(); df.dateFormat = "MMMM d, yyyy"
        let dateline = texts(p1).first { $0.0 == "\(df.string(from: issue.date)) | Vol. \(issue.volume) Ed. \(issue.edition)" }
        check("the front page draws the red bar, the nameplate and the dateline from the Header", bar && plate && dateline != nil, "bar \(bar) nameplate \(plate) dateline \(dateline?.0 ?? "missing")")
        check("  the dateline ends at the house right edge, on the house baseline",
              dateline.map { abs($0.1.maxX - F.datelineRight) < 1.01 && abs($0.1.minY + HouseStyle.font("Raleway-SemiBold", 12).ascender - F.datelineBaseline) < 0.01 } ?? false,
              dateline.map { "\($0.1)" } ?? "")
        check("  an empty teaser frame draws nothing", !texts(p1).contains { $0.0 == "Inside" || $0.0.hasPrefix("Page ") })
        let p2 = pages[1]
        let folioDF = DateFormatter(); folioDF.dateFormat = Frame.defaultDateFormat
        let t2 = texts(p2)
        let site = t2.first { $0.0 == "poly.rpi.edu" }
        let date = t2.first { $0.0 == folioDF.string(from: issue.date) }
        check("an inside page draws the Folio: poly.rpi.edu, the date as EEEE, MMMM d, yyyy", site != nil && date != nil,
              "site \(site?.1.minX ?? -1) date \(date?.0 ?? "missing")")
        check("  on the house baseline, the site at the left edge and the date centred",
              site.map { abs($0.1.minX - HouseStyle.Folio.left) < 0.01 && abs($0.1.minY + HouseStyle.font(Frame.fieldFace, 12).ascender - HouseStyle.Folio.baseline) < 0.01 } ?? false
              && date.map { abs($0.1.midX - HouseStyle.page.width / 2) < 1.01 } ?? false, "\(site?.1 ?? .zero) \(date?.1 ?? .zero)")
        let rule = p2.ops.contains { if case let .line(a, b, w, _) = $0 { abs(a.y - HouseStyle.Folio.rule) < 0.01 && abs(a.x - HouseStyle.Folio.ruleLeft) < 0.01 && abs(b.x - HouseStyle.Folio.right) < 0.01 && w == 0.5 } else { false } }
        check("  and the rule", rule)
        let expect = p2.section.isEmpty ? "2" : "\(p2.section)  •  2"
        let number = t2.first { $0.0 == expect }
        check("  the desk and page number read \"\(expect)\", ending at the right edge", number.map { abs($0.1.maxX - HouseStyle.Folio.right) < 1.01 } ?? false,
              "\(t2.filter { $0.0.hasSuffix("2") }.map(\.0))")
        // a mixed page: two stories of different desks, so the folio carries just the number
        do {
            var mixed = issue
            let a = stories.first!
            guard let other = stories.first(where: { $0.desk != a.desk }) else { check("a mixed page carries just its number", false, "every seed story is on one desk"); return }
            mixed.layout!.pages[1].stories = [
                StoryBlock(article: a.id, frame: Box(x: 36, y: HouseStyle.insideTop, w: 300, h: 500), columns: 1, headlineSize: 28),
                StoryBlock(article: other.id, frame: Box(x: 400, y: HouseStyle.insideTop, w: 300, h: 500), columns: 1, headlineSize: 28)]
            mixed.layout!.pages[1].insets = []
            let m = composer.compose(mixed)[1]
            let drawn = texts(m).filter { $0.0.hasSuffix("2") && abs($0.1.maxX - HouseStyle.Folio.right) < 1.01 }.map(\.0)
            check("a mixed page carries just its number", m.section.isEmpty && drawn == ["2"], "section \"\(m.section)\" drawn \(drawn)")
            var one = mixed
            one.layout!.pages[1].stories.removeLast()
            let o = composer.compose(one)[1]
            let drawn1 = texts(o).filter { $0.0.hasSuffix("2") && abs($0.1.maxX - HouseStyle.Folio.right) < 1.01 }.map(\.0)
            check("  a page of one desk names it", drawn1 == ["\(a.desk.rawValue)  •  2"], "\(drawn1)")
        }
        // the template rule on its own
        do {
            let f = Frame(type: .pageNumber, box: Box(x: 0, y: 0, w: 10, h: 10), template: "[{desk}  •  ]{page}")
            check("a field template drops a bracketed part whose fact is empty", Composer.fieldText(f, issue: issue, number: 6, section: "") == "6"
                  && Composer.fieldText(f, issue: issue, number: 6, section: "Sports") == "Sports  •  6"
                  && Composer.fieldText(Frame(type: .date, box: f.box, dateFormat: "yyyy", template: "{date} | Vol. {volume}"), issue: issue, number: 1, section: "") == "\(Calendar.current.component(.year, from: issue.date)) | Vol. \(issue.volume)")
        }

        // 3. the Header filled by hand with stories 3–5 draws them as the paper teased them
        issue.fillHeader(with: Array(stories.dropFirst(2).prefix(3)))
        let filled = issue.header(on: 0)!
        let teased = Array(stories.dropFirst(2).prefix(3))
        check("filling the Header puts stories 3–5 in its frames A, B, C and the first photo in its image frame",
              BuiltInComponents.headerTeaserLinks.enumerated().allSatisfy { k, l in filled.fills.contains { $0.link == l && $0.article == teased[k].id } }
              && filled.fills.contains { $0.frame == BuiltInComponents.headerImageFrame && $0.photo == teased.first { !$0.photos.isEmpty }?.photos[0].id },
              "\(filled.fills.map { "\($0.link ?? "img")→\($0.article.map { id in teased.firstIndex { $0.id == id } ?? -1 } ?? -1)" })")
        let f1 = composer.compose(issue)[0]
        let heads = texts(f1).filter { t in teased.contains { $0.teaserHeadline == t.0 } }
        let labels = texts(f1).filter { $0.0 == "Inside" || $0.0.hasPrefix("Page ") }
        check("  the front page draws the three teaser headlines in their columns", heads.count == 3
              && zip(heads.sorted { $0.1.minX < $1.1.minX }, F.teaserColumns).allSatisfy { abs($0.1.minX - $1.x) < 0.01 && abs($0.1.width - $1.width) < 0.01 },
              "\(heads.map { "\($0.0.prefix(20)) at \($0.1.minX)" })")
        let where3 = teased.map { a in issue.layout!.pages.firstIndex { p in p.stories.contains { $0.article == a.id } } }
        check("  with where each runs over it in the bar", labels.count == 3 && labels.allSatisfy { abs($0.1.minY + HouseStyle.font("Raleway-SemiBold", 12).ascender - F.teaserLabelBaseline) < 0.01 }
              && zip(labels.sorted { $0.1.minX < $1.1.minX }, where3).allSatisfy { $0.0 == ($1.map { "Page \($0 + 1)" } ?? "Inside") },
              "\(labels.map(\.0)) vs \(where3.map { $0.map { "Page \($0 + 1)" } ?? "Inside" })")
        let photo = f1.ops.contains { if case let .image(_, r, outline, _) = $0 { r == F.teaserPhoto && outline == 0 } else { false } }
        check("  and the teaser photo in the house spot, with no outline", photo)

        // 4. the teaser setting: the house 16 pt, two lines, or three; the size comes down only when it must
        do {
            let rc = ResolvedComponent(filled, in: issue, pageColumns: layout.columns)!
            let frames = rc.version.frames.filter { $0.type == .teaserHeadline }.map { rc.rect($0.box) }
            var long = Article(); long.headline = "Rensselaer loses both games to Maine in back-to-back matches"
            var short = Article(); short.headline = "Pipe bursts in CBIS"
            func setting(_ a: [Article]) -> Composer.TeaserSetting { composer.teaserSetting(zip(frames, a).map { ($0, $1) }) }
            let t = setting([long, short, short])
            let needed = composer.height(of: Composer.teaser(long.teaserHeadline, size: t.size, lineHeight: t.lineHeight), width: frames[0].width)
            check("a long teaser headline sets whole, clear of the nameplate, never with an ellipsis",
                  needed <= t.height - 1 && frames[0].minY + t.drop + t.height <= F.nameplate.minY - 1 + 0.01,
                  String(format: "%.1f pt, %d lines, needs %.1f, ends %.1f", t.size, t.lines, needed, frames[0].minY + t.drop + t.height))
            var medium = Article(); medium.headline = "Engineers outpaced by the Colonials"
            let m = setting([medium, short, short])
            check("a headline of a line or two keeps 16 pt, two lines from the house teaser top", m.size == 16 && m.lines == 2 && frames[0].minY + m.drop == F.teaserTop,
                  String(format: "%.1f pt, %d lines, top %.1f", m.size, m.lines, frames[0].minY + m.drop))
            long.teaser = "Maine sweeps women’s hockey"
            let s = setting([long, short, short])
            check("a story's own teaser text keeps the house size", s.size == 16 && s.lines == 2, String(format: "%.1f pt, %d lines", s.size, s.lines))
            // a headline that takes three lines at 16 pt in the first column, measured, not guessed: a 60-odd character
            // headline takes four there (as "Rensselaer loses…" above does) and rightly comes down to 12 pt
            func linesAt16(_ h: String) -> Int {
                let lh = 16 * 1.15
                return Int((composer.height(of: Composer.teaser(h, size: 16, lineHeight: 1.15), width: frames[0].width) / lh).rounded())
            }
            let candidates = ["Student senate votes to change club funding", "Student senate votes to change how clubs are funded",
                              "Senate votes to change how club funding works", "Student senate changes club funding", "Student senate votes on club funding rules"]
            if let h = candidates.first(where: { linesAt16($0) == 3 }) {
                var three = Article(); three.headline = h
                let th = setting([three, short, short])
                check("a headline that needs three lines keeps 16 pt and starts higher", th.size == 16 && th.lines == 3 && frames[0].minY + th.drop == F.teaserTopThreeLines,
                      String(format: "\"%@\": %.1f pt, %d lines, top %.1f", h, th.size, th.lines, frames[0].minY + th.drop))
            } else {
                check("a headline that needs three lines keeps 16 pt and starts higher", false,
                      "no sample headline takes three lines at 16 pt: \(candidates.map { "\(linesAt16($0))" }.joined(separator: ", ")) lines")
            }
            check("the group sets together: one setting drawn for all three",
                  Set(texts(f1).filter { t in teased.contains { $0.teaserHeadline == t.0 } }.map { $0.1.minY }).count == 1)
        }

        // 5. migration: an issue saved before components opens with the Header filled as it was teased
        do {
            var old = issue
            let photoStory = teased.first { !$0.photos.isEmpty }!
            for i in old.layout!.pages.indices { old.layout!.pages[i].components = [] }
            old.componentVersions = []
            var json = try! JSONSerialization.jsonObject(with: IssueStore.encoder().encode(old)) as! [String: Any]
            json["format"] = nil
            var l = json["layout"] as! [String: Any]
            var ps = l["pages"] as! [[String: Any]]
            ps[0]["teasers"] = teased.map { $0.id.uuidString }
            var insets = ps[0]["insets"] as! [[String: Any]]
            insets.append(["id": UUID().uuidString, "kind": "teaser", "article": photoStory.id.uuidString, "photo": photoStory.photos[0].id.uuidString,
                           "frame": ["x": F.teaserPhoto.minX, "y": F.teaserPhoto.minY, "w": F.teaserPhoto.width, "h": F.teaserPhoto.height], "focusX": 0.25, "focusY": 0.5])
            ps[0]["insets"] = insets
            l["pages"] = ps; json["layout"] = l
            let url = data.appendingPathComponent("old-format.json")
            try! JSONSerialization.data(withJSONObject: json).write(to: url)
            if let back = IssueStore.load(from: url) {
                let h = back.header(on: 0)
                check("an issue saved before components opens with the Header on page 1 and the Folio inside",
                      h != nil && back.layout!.pages.dropFirst().allSatisfy { $0.components.map(\.component) == [BuiltInComponents.folioID] }
                      && Set(back.componentVersions.map(\.id)) == [BuiltInComponents.headerID, BuiltInComponents.folioID] && back.format == Issue.currentFormat,
                      "header \(h != nil) format \(back.format)")
                let img = h?.fills.first { $0.frame == BuiltInComponents.headerImageFrame }
                check("  filled with the stories it teased and its teaser photo, crop and all",
                      BuiltInComponents.headerTeaserLinks.enumerated().allSatisfy { k, l in h?.fills.contains { $0.link == l && $0.article == teased[k].id } ?? false }
                      && img?.article == photoStory.id && img?.photo == photoStory.photos[0].id && img?.focusX == 0.25,
                      "\(h?.fills.map { "\($0.link ?? "img")" } ?? []) focus \(img?.focusX ?? -1)")
                check("  the old teaser inset is gone and nothing is left to migrate", !back.layout!.pages[0].insets.contains { $0.article == photoStory.id && $0.frame.rect == F.teaserPhoto }
                      && back.layout!.pages[0].legacyTeasers.isEmpty && back.layout!.pages[0].legacyTeaserPhoto == nil)
                let a = composer.compose(back)[0], b = composer.compose(issue)[0]
                check("  and draws the same front page as the Header filled by hand", texts(a).map(\.0) == texts(b).map(\.0) && a.ops.count == b.ops.count, "\(a.ops.count) vs \(b.ops.count) ops")
                // saved again, it stays in the new format and the legacy keys aren't written
                let again = try! IssueStore.encoder().encode(back)
                let j = try! JSONSerialization.jsonObject(with: again) as! [String: Any]
                let page1 = ((j["layout"] as! [String: Any])["pages"] as! [[String: Any]])[0]
                check("  saved again, the file carries the format and no teasers key", j["format"] as? Int == Issue.currentFormat && page1["teasers"] == nil)
            } else { check("an issue saved before components opens with the Header on page 1 and the Folio inside", false, "couldn't read it back") }
            // an issue already in the new format is left alone, even with the Header removed
            var bare = issue
            bare.layout!.pages[0].components = []
            let d = try! IssueStore.encoder().encode(bare)
            try! d.write(to: url)
            check("an issue in the new format keeps a front page the user cleared of its Header", IssueStore.load(from: url)?.layout?.pages[0].components.isEmpty == true)
            try? FileManager.default.removeItem(at: url)
        }

        // 6. Clear Pages and Add Page put the components on, like the generator
        do {
            // each command its own undo step, as two menu picks are in the app: the self-test runs in one turn of the
            // run loop, so with the store's event-grouped undo manager both (and every edit before them) undo as one
            let savedUndo = store.undoManager
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.undoManager = undo
            defer { store.undoManager = savedUndo }
            func step(_ f: () -> Void) { undo.beginUndoGrouping(); f(); undo.endUndoGrouping() }
            let was = store.issue
            step { store.clearPages() }
            let cleared = store.issue.layout!
            check("Clear Pages leaves the Header on page 1 and the Folio on the rest",
                  cleared.pages[0].components.map(\.component) == [BuiltInComponents.headerID]
                  && cleared.pages.dropFirst().allSatisfy { $0.components.map(\.component) == [BuiltInComponents.folioID] }, "\(cleared.pages.map { $0.components.count })")
            step { store.addPage() }
            check("Add Page gives the new page a Folio", store.issue.layout!.pages.last?.components.map(\.component) == [BuiltInComponents.folioID])
            let names = [undo.undoActionName]
            undo.undo()
            let afterOne = store.issue.layout?.pages.count ?? 0
            undo.undo()
            check("  both undo", store.issue.layout == was.layout,
                  "\(was.layout?.pages.count ?? 0) pages before, \(afterOne) after one undo (\(names[0])), \(store.issue.layout?.pages.count ?? 0) after two; components \(store.issue.layout?.pages.map { $0.components.count } ?? []) vs \(was.layout?.pages.map { $0.components.count } ?? [])")
        }

        // 7. the shipped files are what the code builds
        for (name, built) in [("Header", BuiltInComponents.makeHeader()), ("Folio", BuiltInComponents.makeFolio())] {
            let shipped = name == "Header" ? BuiltInComponents.header : BuiltInComponents.folio
            check("the shipped \(name) component matches the house style it was built from", shipped == built,
                  shipped.versions.first.map { v in "\(v.elements.count) elements, \(v.width)×\(v.height)" } ?? "no version")
        }

        // 8. Export for InDesign writes the placed components as the pages draw them: the Header with its teasers,
        // their pages and the teaser photo; the Folio on the pages that have it; nothing for one taken off
        idml(check, composer: composer, base: store.issue, stories: stories, data: data)

        // 9. the Priority step no longer promises teasers: stories 3–5 go inside like the rest
        let ranked = store.issue.articles.filter { $0.body.contains { !$0.trimmed.isEmpty } }
        check("Priority places stories 3–5 inside, not teased on the front",
              ranked.count >= 5 && ranked[2..<5].allSatisfy { store.placements[$0.id] == .inside }
              && store.placements[ranked[0].id] == .frontLead && store.placements[ranked[1].id] == .front,
              "\(ranked.prefix(5).map { "\(store.placements[$0.id].map { "\($0)" } ?? "nil")" })")
    }

    /// The IDML package for an issue, read back: its spreads in page order and its stories' text by id.
    static func readIDML(_ issue: Issue, composer: Composer, to url: URL) throws -> (spreads: [String], stories: [String: String]) {
        let pages = composer.compose(issue)
        try IDMLExport.write(issue, pages: pages, composer: composer, to: url)
        let dir = url.deletingPathExtension().appendingPathExtension("unzipped")
        try? FileManager.default.removeItem(at: dir)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-q", "-o", url.path, "-d", dir.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let map = try String(contentsOf: dir.appendingPathComponent("designmap.xml"), encoding: .utf8)
        let ids = map.matches(of: #/Spreads\/Spread_(\w+)\.xml/#).map { String($0.1) }
        let spreads = try ids.map { try String(contentsOf: dir.appendingPathComponent("Spreads/Spread_\($0).xml"), encoding: .utf8) }
        var stories: [String: String] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Stories").path)) ?? [] {
            let xml = try String(contentsOf: dir.appendingPathComponent("Stories").appendingPathComponent(file), encoding: .utf8)
            guard let sid = xml.firstMatch(of: #/<Story Self="(\w+)"/#)?.1 else { continue }
            stories[String(sid)] = xml
        }
        return (spreads, stories)
    }

    @MainActor
    private static func idml(_ report: (String, Bool, String) -> Void, composer: Composer, base: Issue, stories: [Article], data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        typealias F = HouseStyle.Front
        var issue = base
        issue.generateLayout(composer: composer, seed: 1)
        let teased = Array(stories.dropFirst(2).prefix(3))
        issue.fillHeader(with: teased)
        guard issue.layout!.pages.count >= 3 else { check("IDML: the seed paper has three pages", false); return }
        /// The text of a story, as the export wrote it (entities undone).
        func text(_ xml: String) -> String {
            xml.matches(of: #/<Content>([^<]*)<\/Content>/#).map { String($0.1) }.joined()
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        }
        /// The stories a spread's text frames show, with their paragraph style and text.
        func texts(_ spread: String, _ all: [String: String]) -> [(style: String, text: String)] {
            spread.matches(of: #/ParentStory="(\w+)"/#).compactMap { m in
                all[String(m.1)].map { xml in (String(xml.firstMatch(of: #/AppliedParagraphStyle="ParagraphStyle\/([^"]*)"/#)?.1 ?? ""), text(xml)) }
            }
        }
        func num(_ v: CGFloat) -> String {
            var s = String(format: "%.4f", Double(v))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        func at(_ r: CGRect) -> String { "ItemTransform=\"1 0 0 1 \(num(r.minX - HouseStyle.page.width / 2)) \(num(r.minY - HouseStyle.page.height / 2))\"" }
        let red = "FillColor=\"Color/C=15 M=100 Y=100 K=0\""
        do {
            let (spreads, all) = try readIDML(issue, composer: composer, to: data.appendingPathComponent("selftest-header.idml"))
            guard spreads.count == issue.layout!.pages.count else { check("IDML: one spread per page", false, "\(spreads.count) spreads"); return }
            let front = texts(spreads[0], all)
            let heads = front.filter { $0.style == "Teaser" }.map(\.text)
            check("IDML: the front page carries the Header's three teaser headlines", heads == teased.map(\.teaserHeadline),
                  "\(heads.map { String($0.prefix(24)) })")
            let where3 = teased.map { a in issue.layout!.pages.firstIndex { p in p.stories.contains { $0.article == a.id } } }
            let labels = front.filter { $0.style == "Teaser Page" }.map(\.text)
            check("  with the page each runs on", labels == where3.map { $0.map { "Page \($0 + 1)" } ?? "Inside" }, "\(labels)")
            check("  the red bar, the nameplate and the dateline", spreads[0].contains(red) && spreads[0].contains(at(F.nameplate))
                  && front.contains { $0.style == "Dateline" && $0.text.contains("| Vol. \(issue.volume) Ed. \(issue.edition)") }, "\(front.filter { $0.style == "Dateline" }.map(\.text))")
            check("  and the teaser photo in its frame, with no outline", spreads[0].contains("ContentType=\"GraphicType\"") && spreads[0].contains(at(F.teaserPhoto))
                  && spreads[0].components(separatedBy: at(F.teaserPhoto)).dropLast().contains { $0.hasSuffix("ContentType=\"GraphicType\" StoryTitle=\"$ID/\" Visible=\"true\" Name=\"$ID/\" ItemLayer=\"ucc\" Locked=\"false\" LocalDisplaySetting=\"Default\" FillColor=\"Swatch/None\" StrokeWeight=\"0\" StrokeColor=\"Swatch/None\" AppliedObjectStyle=\"ObjectStyle/$ID/[None]\" ") })
            let folios = spreads.dropFirst().map { texts($0, all).filter { $0.style == "Folio" }.map(\.text) }
            let df = DateFormatter(); df.dateFormat = Frame.defaultDateFormat
            check("IDML: every inside page carries the Folio: the site, the date and its number",
                  folios.enumerated().allSatisfy { k, t in t.contains("poly.rpi.edu") && t.contains(df.string(from: issue.date)) && t.contains { $0 == "\(k + 2)" || $0.hasSuffix("•  \(k + 2)") } },
                  "\(folios.map { $0.joined(separator: " / ") })")
            check("  and the front page doesn't", !texts(spreads[0], all).contains { $0.text == "poly.rpi.edu" })
        } catch { check("IDML: the export with the Header filled", false, "\(error)") }

        // the components taken off: the export follows the page, not the house furniture
        issue.layout!.pages[0].components = []
        issue.layout!.pages[1].components = []
        do {
            let (spreads, all) = try readIDML(issue, composer: composer, to: data.appendingPathComponent("selftest-header-bare.idml"))
            check("IDML: a front page without the Header has no bar, nameplate, dateline or teasers",
                  !spreads[0].contains(red) && !spreads[0].contains(at(F.nameplate)) && !texts(spreads[0], all).contains { ["Teaser", "Teaser Page", "Dateline"].contains($0.style) })
            check("  an inside page without the Folio has no folio, and the next page keeps its own",
                  !texts(spreads[1], all).contains { $0.text == "poly.rpi.edu" } && texts(spreads[2], all).contains { $0.text == "poly.rpi.edu" })
        } catch { check("IDML: the export without the Header and a Folio", false, "\(error)") }
    }
}
