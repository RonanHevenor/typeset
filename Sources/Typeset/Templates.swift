import AppKit

// Templates (phase 8). A template is an issue without stories: pages with components placed on them, and a copy
// of every component version those pages use, so a `.typesettemplate` file stands alone as a `.typeset` file
// does. New Issue starts from one; the generator lays the stories out in the space its components leave; Add Page
// puts its repeating components on a new page. The app ships one, The Polytechnic (the Header on page 1, the Folio
// on the rest), which is what an issue made before templates gets.

/// Which pages a repeating component goes on when a page is added: every page, or every page but the front.
enum Repeat: String, Codable, Hashable {
    case allPages, insidePages
    func applies(toFront front: Bool) -> Bool { self == .allPages || !front }
}

struct IssueTemplate: Codable, Hashable {
    var name: String
    /// The pages, front first. Only their components count: a template has no stories, pictures or fills.
    var pages: [PageLayout] = []
    /// A copy of every component version the pages use.
    var componentVersions: [Component] = []
    var format = 1

    static let fileExtension = "typesettemplate"
    static let typeIdentifier = "edu.rpi.poly.galley.template"

    private enum CodingKeys: String, CodingKey { case name, pages, componentVersions, format }

    init(name: String, pages: [PageLayout], componentVersions: [Component]) {
        self.name = name
        self.pages = Self.clean(pages)
        self.componentVersions = componentVersions
    }

    /// Lenient, as everywhere: a page, placement, component or version that can't be read is dropped on its own.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, or: "Template")
        pages = Self.clean(c.lossy(.pages))
        componentVersions = c.lossy(.componentVersions)
        format = c.value(.format, or: 1)
    }

    /// Pages as a template keeps them: the first is the front; no stories, pictures or fills.
    static func clean(_ pages: [PageLayout]) -> [PageLayout] {
        pages.enumerated().map { i, p in
            var q = PageLayout(isFront: i == 0)
            q.id = p.id
            q.components = p.components.map { var c = $0; c.fills = []; return c }
            return q
        }
    }

    /// Save as Template…: an issue's pages and components, without its stories and fills. Only the component
    /// versions the pages use go with it (a custom copy travels in its placement).
    init(issue: Issue, name: String) {
        self.init(name: name, pages: issue.layout?.pages ?? [PageLayout(isFront: true)], componentVersions: [])
        var used = Issue()
        used.layout = IssueLayout(pages: pages)
        used.componentVersions = issue.componentVersions
        used.pruneComponentVersions()
        componentVersions = used.componentVersions
    }

    /// The components a page repeats on new pages, one per component, in page order.
    var repeaters: [PlacedComponent] { Self.repeaters(in: pages) }
    static func repeaters(in pages: [PageLayout]) -> [PlacedComponent] {
        var out: [PlacedComponent] = []
        for p in pages {
            for c in p.components where c.repeats != nil && !out.contains(where: { $0.component == c.component }) { out.append(c) }
        }
        return out
    }

    /// What page `i` of an issue made from this template carries: the template's own page, or past its last page,
    /// its repeating components. Fresh placements, empty frames.
    func components(forPage i: Int, isFront: Bool) -> [PlacedComponent] {
        let from = pages.indices.contains(i) ? pages[i].components : repeaters.filter { $0.repeats!.applies(toFront: isFront) }
        return from.map { var c = $0; c.id = UUID(); c.fills = []; return c }
    }

    /// How many pages an issue made from it keeps even when its stories don't reach them: up to the last page that
    /// carries something besides repeating components (a page made only of those is an ordinary inside page,
    /// which the generator adds as the stories need it).
    var keptPageCount: Int {
        (pages.lastIndex { p in p.components.contains { $0.repeats == nil } } ?? 0) + 1
    }

    // MARK: the file

    static func read(_ url: URL) throws -> IssueTemplate {
        try IssueStore.decoder().decode(IssueTemplate.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        try IssueStore.encoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The template the app ships.
enum BuiltInTemplates {
    static let polytechnicName = "The Polytechnic"

    /// The Polytechnic: the Header on the front page, the Folio on the three inside pages, repeating on every
    /// inside page added. An issue made from it lays out exactly as one made before templates.
    static let polytechnic: IssueTemplate = {
        var pages = (0..<4).map { PageLayout(isFront: $0 == 0) }
        let header = BuiltInComponents.header, folio = BuiltInComponents.folio
        var versions: [Component] = []
        if let v = header.latest {
            pages[0].components.append(PlacedComponent(component: header.id, version: v.number, frame: Box(x: BuiltInComponents.headerOrigin.x, y: BuiltInComponents.headerOrigin.y, w: v.width, h: v.height)))
            versions.append(Component(name: header.name, versions: [v]).with(id: header.id))
        }
        if let v = folio.latest {
            for i in 1..<pages.count {
                pages[i].components.append(PlacedComponent(component: folio.id, version: v.number, frame: Box(x: BuiltInComponents.folioOrigin.x, y: BuiltInComponents.folioOrigin.y, w: v.width, h: v.height),
                                                           repeats: .insidePages))
            }
            versions.append(Component(name: folio.name, versions: [v]).with(id: folio.id))
        }
        return IssueTemplate(name: polytechnicName, pages: pages, componentVersions: versions)
    }()
}

extension Issue {
    /// The template the pages come from: the one the issue was made from, or The Polytechnic.
    var pagePlan: IssueTemplate { template ?? BuiltInTemplates.polytechnic }

    /// What the generator and Clear Pages put on page `i` (`IssueTemplate.components(forPage:isFront:)`).
    func templateComponents(forPage i: Int, isFront: Bool) -> [PlacedComponent] {
        pagePlan.components(forPage: i, isFront: isFront)
    }

    /// Copies into the issue any version its pages use that it doesn't have yet, from its template (or the
    /// shipped components), so the file stands alone.
    mutating func embedPlacedVersions() {
        let sources = pagePlan.componentVersions + BuiltInComponents.all
        for p in (layout?.pages ?? []).flatMap(\.components) where version(of: p) == nil {
            if let c = sources.first(where: { $0.id == p.component && $0.version(p.version) != nil }) { embed(c, version: p.version) }
        }
    }

    /// Clear Pages: every page gets its template's components back.
    mutating func placeTemplateComponents() {
        guard layout != nil else { return }
        for i in layout!.pages.indices {
            layout!.pages[i].components = templateComponents(forPage: i, isFront: layout!.pages[i].isFront)
        }
        embedPlacedVersions()
    }

    /// Add Page: the new page gets every component marked as repeating on the other pages (one of each, where the
    /// first such page has it), with empty frames. Nothing else: a component unmarked with Don't Repeat on New
    /// Pages, or removed from every page, stays off. (An issue from before templates had its Folio marked when it
    /// was opened, `markTemplateRepeaters`, so it still gets one.)
    mutating func placeRepeaters(onPage at: Int) {
        guard let l = layout, l.pages.indices.contains(at) else { return }
        let reps = IssueTemplate.repeaters(in: l.pages.enumerated().filter { $0.offset != at }.map(\.element))
        let front = l.pages[at].isFront
        for r in reps where r.repeats!.applies(toFront: front) && !l.pages[at].components.contains(where: { $0.component == r.component }) {
            var q = r; q.id = UUID(); q.fills = []
            layout!.pages[at].components.append(q)
        }
        embedPlacedVersions()
    }

    /// New Issue from a template: its pages with its components placed (their issue fields fill themselves), no
    /// stories yet. Generating the paper lays the stories out around them.
    mutating func start(from t: IssueTemplate) {
        template = t
        for c in t.componentVersions { for v in c.versions { embed(c, version: v.number) } }
        var l = IssueLayout()
        l.columns = HouseStyle.columns(averageCharWidth: HouseStyle.averageCharWidth(of: "")).columns
        l.pages = t.pages.indices.map { i in
            var p = PageLayout(isFront: i == 0)
            p.components = t.components(forPage: i, isFront: i == 0)
            return p
        }
        layout = l
        embedPlacedVersions()
    }
}

extension Issue {
    /// The paper hasn't been generated yet: no pages, or only the pages New Issue started from a template with
    /// (its components, nothing placed or filled) while there are stories to lay out. Going to the Pages step
    /// generates it then, as it did when a new issue had no pages.
    var paperNotGenerated: Bool {
        guard let l = layout else { return true }
        return !articles.isEmpty && l.basis.isEmpty
            && l.pages.allSatisfy { $0.stories.isEmpty && $0.insets.isEmpty && $0.components.allSatisfy(\.fills.isEmpty) }
    }

    /// Opening a file from before templates (format 2 or older), whose placements carry no repeat marks: the
    /// components its template repeats (The Polytechnic's Folio) are marked as repeating where they're placed, so
    /// Add Page goes on putting the Folio on new pages, and Don't Repeat on New Pages can stop it.
    mutating func markTemplateRepeaters() {
        guard layout != nil, !layout!.pages.contains(where: { $0.components.contains { $0.repeats != nil } }) else { return }
        for r in pagePlan.repeaters {
            for i in layout!.pages.indices {
                for k in layout!.pages[i].components.indices where layout!.pages[i].components[k].component == r.component {
                    layout!.pages[i].components[k].repeats = r.repeats
                }
            }
        }
    }
}
