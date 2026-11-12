import AppKit

// The two components the app ships (phase 4): the front page's Header and the inside pages' Folio, which the app
// used to draw by itself (`frontMatter` and `folio` in Composer.swift). They are built here from the house style's
// measurements and written to `Resources/Components/*.typesetcomponent`; the app reads those files from its
// bundle and only builds them again when a file is missing. Their ids are fixed, so a file that uses "the Header"
// means the same component on every Mac.

enum BuiltInComponents {
    static let headerID = UUID(uuidString: "7E4A1B2C-0001-4C5D-9E6F-A1B2C3D4E5F6")!
    static let folioID = UUID(uuidString: "7E4A1B2C-0002-4C5D-9E6F-A1B2C3D4E5F6")!

    // the Header's frames, by id: the generator and the migration fill them, and `--fill-header` does by hand
    static let headerImageFrame = UUID(uuidString: "7E4A1B2C-0011-4C5D-9E6F-A1B2C3D4E5F6")!
    static let headerTeaserLinks = ["A", "B", "C"]

    static let fileExtension = "typesetcomponent"

    /// The two as this paper has them: the shipped files carry no nameplate and no website, so the ones from setup
    /// (Setup.swift) go in here, when a new issue or page takes them.
    static var header: Component { withPaper(loaded["Header"] ?? makeHeader()) }
    static var folio: Component { withPaper(loaded["Folio"] ?? makeFolio()) }
    static var all: [Component] { [header, folio] }
    /// Which of the two the bundle carries as files (the rest are built in code).
    static var shippedNames: [String] { ["Header", "Folio"].filter { loaded[$0] != nil } }

    private static var loaded: [String: Component] = {
        var out: [String: Component] = [:]
        for name in ["Header", "Folio"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Components")
                    ?? Bundle.main.url(forResource: name, withExtension: fileExtension),
                  let data = try? Data(contentsOf: url), let c = try? IssueStore.decoder().decode(Component.self, from: data) else { continue }
            out[name] = c
        }
        return out
    }()

    /// Writes both components as files into `dir` (the harness's `--make-components`), with a fixed date so the
    /// files only change when the components do.
    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // without a nameplate or website: those are each paper's own, put in from setup when they're used
        for c in [makeHeader(), makeFolio()].map({ withPaper($0, nameplate: nil, host: "") }) {
            try IssueStore.encoder().encode(c).write(to: dir.appendingPathComponent(c.name).appendingPathExtension(fileExtension))
        }
    }

    private static let madeOn = Date(timeIntervalSince1970: 1_793_664_000)      // 3 Nov 2026
    /// A fixed id for an element, so the files only change when the components do.
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "7E4A1B2C-%04X-4C5D-9E6F-A1B2C3D4E5F6", n))! }

    /// The text box `Composer.label` draws a line of type in, for a baseline: the frame a field sits in.
    private static func fieldBox(face: String, size: CGFloat, baseline: CGFloat, x: CGFloat, width: CGFloat, origin: CGPoint) -> Box {
        let f = HouseStyle.font(face, size)
        return Box(x: x - origin.x, y: baseline - f.ascender - origin.y, w: width, h: ceil(f.ascender - f.descender) + 2)
    }

    /// The front page's header: the red bar, three teaser headlines (A, B, C) with the page each story runs on,
    /// the teaser photo, the nameplate, and the dateline, as `HouseStyle.Front` places them.
    static func makeHeader() -> Component {
        typealias F = HouseStyle.Front
        let origin = CGPoint(x: F.teaserPhoto.minX, y: F.teaserPhoto.minY)
        let width = F.nameplate.maxX - origin.x
        let height = F.nameplate.maxY - origin.y
        func box(_ r: CGRect) -> Box { Box(x: r.minX - origin.x, y: r.minY - origin.y, w: r.width, h: r.height) }
        var bar = ShapeElement(box: box(F.teaserBar), fill: .red)
        bar.id = id(0x0001)
        var elements: [Element] = [.rect(bar)]
        var image = Frame(type: .image, box: box(F.teaserPhoto), outline: false)
        image.id = headerImageFrame
        elements.append(.frame(image))
        for (letter, col) in zip(headerTeaserLinks, F.teaserColumns) {
            // "Page 5" in the bar, then the headline: the frame runs from the bar's top to a point above the nameplate
            var page = Frame(type: .teaserPage, box: fieldBox(face: "Raleway-SemiBold", size: 12, baseline: F.teaserLabelBaseline, x: col.x + F.teaserLabelInset, width: col.width - F.teaserLabelInset, origin: origin),
                             link: letter, color: .white, face: "Raleway-SemiBold")
            page.id = UUID(uuidString: "7E4A1B2C-001\(letter)-4C5D-9E6F-A1B2C3D4E5F6")!
            elements.append(.frame(page))
            let r = CGRect(x: col.x, y: F.teaserBar.minY, width: col.width, height: F.nameplate.minY - 1 - F.teaserBar.minY)
            var f = Frame(type: .teaserHeadline, box: box(r), link: letter)
            f.id = UUID(uuidString: "7E4A1B2C-002\(letter)-4C5D-9E6F-A1B2C3D4E5F6")!
            elements.append(.frame(f))
        }
        if let art = nameplateArt() { elements.append(.art(art)) }
        var dateline = Frame(type: .date, box: fieldBox(face: "Raleway-SemiBold", size: 12, baseline: F.datelineBaseline, x: F.datelineRight - 400, width: 400, origin: origin),
                             alignment: .right, color: .white, dateFormat: "MMMM d, yyyy", face: "Raleway-SemiBold",
                             template: "{date} | Vol. {volume} Ed. {edition}")
        dateline.id = UUID(uuidString: "7E4A1B2C-0031-4C5D-9E6F-A1B2C3D4E5F6")!
        elements.append(.frame(dateline))
        let v = ComponentVersion(number: 1, width: width, height: height, columns: F.teaserColumns.count, gutter: F.teaserColumns[1].x - F.teaserColumns[0].x - F.teaserColumns[0].width,
                                 elements: elements, date: madeOn)
        return Component(name: "Header", versions: [v]).with(id: headerID)
    }

    /// Where the Header goes on the front page.
    static var headerOrigin: CGPoint { CGPoint(x: HouseStyle.Front.teaserPhoto.minX, y: HouseStyle.Front.teaserPhoto.minY) }

    /// The inside pages' folio: the rule, "poly.rpi.edu", the date, and the desk with the page number.
    static func makeFolio() -> Component {
        typealias Fo = HouseStyle.Folio
        let f = HouseStyle.font(Frame.fieldFace, 12)
        let origin = CGPoint(x: Fo.left, y: Fo.baseline - f.ascender)
        let width = Fo.right - Fo.left
        let height = Fo.rule + Fo.ruleWidth / 2 - origin.y
        var date = Frame(type: .date, box: fieldBox(face: Frame.fieldFace, size: 12, baseline: Fo.baseline, x: HouseStyle.page.width / 2 - 150, width: 300, origin: origin), alignment: .center)
        date.id = UUID(uuidString: "7E4A1B2C-0041-4C5D-9E6F-A1B2C3D4E5F6")!
        var number = Frame(type: .pageNumber, box: fieldBox(face: Frame.fieldFace, size: 12, baseline: Fo.baseline, x: Fo.right - 300, width: 300, origin: origin),
                           alignment: .right, template: "[{desk}  •  ]{page}")
        number.id = UUID(uuidString: "7E4A1B2C-0042-4C5D-9E6F-A1B2C3D4E5F6")!
        var rule = LineElement(from: CGPoint(x: Fo.ruleLeft - origin.x, y: Fo.rule - origin.y), to: CGPoint(x: Fo.right - origin.x, y: Fo.rule - origin.y), width: Fo.ruleWidth)
        rule.id = id(0x0003)
        var site = TextElement(box: fieldBox(face: Frame.fieldFace, size: 12, baseline: Fo.baseline, x: Fo.left, width: 300, origin: origin), text: Paper.host, face: Frame.fieldFace, size: 12)
        site.id = id(0x0004)
        let elements: [Element] = [.line(rule), .text(site), .frame(date), .frame(number)]
        let v = ComponentVersion(number: 1, width: width, height: height, elements: elements, date: madeOn)
        return Component(name: "Folio", versions: [v]).with(id: folioID)
    }

    static let nameplateArtID = id(0x0002)
    static let folioSiteID = id(0x0004)

    /// The Header's nameplate, from setup or the build, placed where the house style puts it.
    static func nameplateArt() -> ArtElement? {
        typealias F = HouseStyle.Front
        guard let url = Paper.nameplateURL, let data = try? Data(contentsOf: url) else { return nil }
        let origin = headerOrigin
        var art = ArtElement(box: Box(x: F.nameplate.minX - origin.x, y: F.nameplate.minY - origin.y, w: F.nameplate.width, h: F.nameplate.height),
                             name: url.lastPathComponent, data: data)
        art.id = nameplateArtID
        return art
    }

    /// `c` with this paper's nameplate (the Header) or website (the Folio) in place of whatever it was built with.
    static func withPaper(_ c: Component) -> Component { withPaper(c, nameplate: nameplateArt(), host: Paper.host) }
    static func withPaper(_ c: Component, nameplate art: ArtElement?, host: String) -> Component {
        var c = c
        if c.id == headerID {
            for i in c.versions.indices {
                var els = c.versions[i].elements
                // where it was, else under the dateline, which is set on the nameplate's bar
                let at = els.firstIndex { $0.id == nameplateArtID } ?? els.firstIndex { $0.frame?.type == .date } ?? els.endIndex
                els.removeAll { $0.id == nameplateArtID }
                if let art { els.insert(.art(art), at: min(at, els.endIndex)) }
                c.versions[i].elements = els
            }
        } else if c.id == folioID {
            for i in c.versions.indices {
                c.versions[i].elements = c.versions[i].elements.map {
                    guard case .text(var t) = $0, t.id == folioSiteID else { return $0 }
                    t.text = host
                    return .text(t)
                }
            }
        }
        return c
    }

    static var folioOrigin: CGPoint { CGPoint(x: HouseStyle.Folio.left, y: HouseStyle.Folio.baseline - HouseStyle.font(Frame.fieldFace, 12).ascender) }
}

extension Issue {
    /// Puts the Header on the front page and the Folio on every inside page that has neither, embedding them.
    /// What the generator, Clear Pages, Add Page and the migration of an older file all start from.
    mutating func placeBuiltIns(on pages: Range<Int>? = nil) {
        guard let l = layout else { return }
        for i in pages ?? l.pages.indices where l.pages.indices.contains(i) {
            let p = l.pages[i]
            let want = p.isFront ? BuiltInComponents.header : BuiltInComponents.folio
            guard !p.components.contains(where: { $0.component == BuiltInComponents.headerID || $0.component == BuiltInComponents.folioID }),
                  let n = want.latest?.number else { continue }
            place(want, version: n, on: i, at: p.isFront ? BuiltInComponents.headerOrigin : BuiltInComponents.folioOrigin)
        }
    }

    /// The Header placed on a page, if any.
    func header(on page: Int) -> PlacedComponent? {
        layout?.pages[safe: page]?.components.first { $0.component == BuiltInComponents.headerID }
    }

    /// Fills the Header's teaser frames with stories, in order (A, B, C), and its image frame with the first of
    /// their photos, as the generator teased stories 3–5 before phase 4. Replaces what the frames held.
    mutating func fillHeader(on page: Int = 0, with stories: [Article], photo: (Article, Photo)? = nil, focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard let k = layout?.pages[safe: page]?.components.firstIndex(where: { $0.component == BuiltInComponents.headerID }) else { return }
        var fills: [Fill] = []
        for (letter, a) in zip(BuiltInComponents.headerTeaserLinks, stories) { fills.append(Fill(link: letter, article: a.id)) }
        let pic = photo ?? stories.lazy.compactMap { a in a.photos.first.map { (a, $0) } }.first
        if let (a, p) = pic {
            var f = Fill(frame: BuiltInComponents.headerImageFrame, article: a.id, photo: p.id)
            f.focusX = focus.x; f.focusY = focus.y
            fills.append(f)
        }
        layout!.pages[page].components[k].fills = fills
    }

    /// Brings an issue saved before phase 4 (format 1) up to date: the Header goes on page 1 filled with the
    /// stories it teased and its teaser photo, and the Folio on every inside page, so the paper looks as it did.
    mutating func migrateComponents() {
        guard format < Issue.currentFormat else { return }
        let old = format
        format = Issue.currentFormat
        guard layout != nil else { return }
        defer { markTemplateRepeaters() }          // format 3: repeat marks (phase 8, Templates.swift)
        guard old < 2 else { return }
        placeBuiltIns()
        for i in layout!.pages.indices {
            let p = layout!.pages[i]
            if p.isFront, header(on: i) != nil {
                let teased = p.legacyTeasers.compactMap { id in articles.first { $0.id == id } }
                let photo = p.legacyTeaserPhoto.flatMap { t in articles.first { $0.id == t.article }.flatMap { a in a.photos.first { $0.id == t.photo }.map { (a, $0) } } }
                fillHeader(on: i, with: teased, photo: photo, focus: p.legacyTeaserPhoto.map { CGPoint(x: $0.focusX, y: $0.focusY) } ?? CGPoint(x: 0.5, y: 0.5))
            }
            layout!.pages[i].legacyTeasers = []
            layout!.pages[i].legacyTeaserPhoto = nil
        }
    }

    /// Lays the paper out with the generator, around the components its template puts on each page (Templates.swift).
    mutating func generateLayout(composer: Composer, seed: UInt64) {
        layout = LayoutGenerator(issue: self, composer: composer, seed: seed).run()
        embedPlacedVersions()
    }
}
