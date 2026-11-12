import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

/// The issue being assembled. Autosaves to ~/Library/Application Support/Typeset/issue.json.
@Observable
final class IssueStore {
    var issue = Issue()
    var selection: Article.ID?
    var search = ""
    /// The paper's staff, from setup (Setup.swift).
    var staff: [StaffMember] { Setup.shared.paper.staff }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Set when the saved issue couldn't be read: what happened and where the file was kept. Shown once on launch.
    var loadProblem: String?
    /// The .typeset file this issue belongs to and whether it has unsaved changes (IssueStore+Files.swift).
    var document = IssueDocument()

    /// `backgroundFits`: copyfit off the main thread (the app). The headless harness and tests fit synchronously.
    init(backgroundFits: Bool = false) {
        if backgroundFits {
            composer.worker = FitWorker()
            composer.onFitsReady = { [weak self] in self?.fitsArrived &+= 1 }
        }
        let saved = Self.saveURL
        if let s = Self.load(from: saved) {
            issue = s
        } else {
            if FileManager.default.fileExists(atPath: saved.path) {
                // the file is there but unreadable: keep it aside before anything can save over it
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
                let kept = Self.supportDir.appendingPathComponent("issue-unreadable-\(f.string(from: Date())).json")
                try? FileManager.default.copyItem(at: saved, to: kept)
                loadProblem = "The saved issue couldn't be read, so Typeset started a new one. The file was kept as \(kept.lastPathComponent) in \(Self.supportDir.path)."
            }
            // a build may carry a seed issue to start from (Resources/Private); otherwise the first issue starts empty
            if let seed = Bundle.main.url(forResource: "seed-issue", withExtension: "json"), let s = Self.load(from: seed) { issue = s }
        }
        selection = issue.articles.first?.id
        restoreDocument()
        // a save still waiting when the app quits is written before it goes
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        composer.onLostDrag = { [weak self] in
            DispatchQueue.main.async { self?.recoverLostDrag() }
        }
    }

    // MARK: storage

    static var supportDir: URL {
        // GALLEY_DATA_DIR points a test run at its own copy of the issue
        if let test = ProcessInfo.processInfo.environment["GALLEY_DATA_DIR"] {
            let dir = URL(fileURLWithPath: test, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return appSupport
    }

    /// ~/Library/Application Support/Typeset. The app was called Galley; the first time Typeset runs, the old
    /// folder is copied across (and left where it is, since imported pictures are referenced by their path there).
    private static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Typeset", isDirectory: true)
        let old = base.appendingPathComponent("Galley", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.appendingPathComponent("issue.json").path) {
            try? fm.copyItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var saveURL: URL { supportDir.appendingPathComponent("issue.json") }
    static var mediaDir: URL {
        let d = supportDir.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e
    }
    static func load(from url: URL) -> Issue? {
        guard let data = try? Data(contentsOf: url), var issue = try? decoder().decode(Issue.self, from: data) else { return nil }
        issue.migrateComponents()                 // a file from before the Header and Folio were components gets them
        // early seeds carried the printed issue's jumps ("### Continued on Page 7", "*Continued from Page 1.*")
        for i in issue.articles.indices {
            issue.articles[i].body.removeAll { $0.range(of: #"^#{1,6}\s*Continued (on|from) Page \d+\.?$"#, options: .regularExpression) != nil }
            issue.articles[i].body = issue.articles[i].body.map {
                $0.replacingOccurrences(of: #"^\*?Continued from Page \d+\.\*?\s*"#, with: "", options: .regularExpression)
            }
        }
        return issue
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write now if a save is waiting.
    func flushSave() {
        guard let t = saveTask else { return }
        t.cancel()
        saveTask = nil
        saveNow()
    }

    func saveNow() {
        if let data = try? Self.encoder().encode(issue) { try? data.write(to: Self.saveURL, options: .atomic); noteWorkingCopy(data) }
    }

    // MARK: queries

    var selectedIndex: Int? {
        guard let id = selection else { return nil }
        return issue.articles.firstIndex { $0.id == id }
    }

    var currentDesk: Desk { selectedIndex.map { issue.articles[$0].desk } ?? .news }

    func articles(on desk: Desk) -> [Article] {
        issue.articles.filter { $0.desk == desk && matches($0) }
    }

    private func matches(_ a: Article) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [a.plainHeadline, a.author, a.bodyText].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var totalWords: Int { issue.articles.reduce(0) { $0 + $1.wordCount } }

    // MARK: actions

    func newArticle(on desk: Desk? = nil) {
        var a = Article()
        a.desk = desk ?? currentDesk
        issue.articles.append(a)
        selection = a.id
        scheduleSave()
    }

    func pasteArticle() {
        // a poly.rpi.edu link on the clipboard is read from the website instead
        if PolyWeb.enabled, let link = NSPasteboard.general.string(forType: .string), !link.contains("\n"), PolyWeb.slug(in: link) != nil {
            addFromLink(link); return
        }
        guard let a = SmartPaste.article(staff: staff, desk: currentDesk) else { NSSound.beep(); return }
        issue.articles.append(a)
        selection = a.id
        scheduleSave()
    }

    // MARK: the website

    /// What's being read from poly.rpi.edu right now, nil when nothing is.
    var webWork: String?

    /// Asks for a story link (the clipboard's, if it holds one) and adds that story.
    func addFromLinkPrompt() {
        let alert = NSAlert()
        alert.messageText = "Add Article from Link"
        alert.informativeText = "A story on poly.rpi.edu. Its text, byline and photos are read from the website."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://poly.rpi.edu/news/2026/10/…"
        if let clip = NSPasteboard.general.string(forType: .string), PolyWeb.slug(in: clip) != nil {
            field.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addFromLink(field.stringValue)
    }

    func addFromLink(_ link: String) {
        guard webWork == nil else { NSSound.beep(); return }
        guard let slug = PolyWeb.slug(in: link) else { tell("Couldn't add that story", PolyWeb.Failure.notThePoly); return }
        if let there = issue.articles.first(where: { PolyWeb.slug(in: $0.source) == slug }) {
            selection = there.id
            tell("That story is already in the issue", "Use Update from Website to bring it up to date.")
            return
        }
        webWork = "Reading the story…"
        Task { @MainActor in
            defer { webWork = nil }
            do {
                let story = try await PolyWeb.story(slug: slug)
                webWork = story.photos.isEmpty ? webWork : "Downloading photos…"
                var a = Article()
                a.desk = story.desk
                a.headline = story.headline
                a.kicker = story.kicker
                a.author = story.author
                a.authorTitle = story.authorTitle
                a.body = story.body
                a.source = story.page.absoluteString
                a.photos = await PolyWeb.download(story.photos, into: Self.mediaDir, keeping: [])
                issue.articles.append(a)
                selection = a.id
                scheduleSave()
            } catch {
                tell("Couldn't add that story", error)
            }
        }
    }

    /// Reads every story in the issue from the website again: the copy and byline are replaced with the site's,
    /// photos the site has and the story doesn't are downloaded, and captions and credits are brought up to date.
    /// Headlines, desks, pull quotes and the layout stay as they are. A story without a link is found by its headline.
    func updateFromWebsite() {
        guard webWork == nil, !issue.articles.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Update \(issue.articles.count) stories from poly.rpi.edu?"
        alert.informativeText = "Each story's text and byline are replaced with the website's, and its photos are downloaded. Headlines and the layout stay as they are. Edit › Undo puts the stories back."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let before = issue.articles
        webWork = "Checking the website…"
        Task { @MainActor in
            defer { webWork = nil }
            var changed: [String] = [], same = 0, newPhotos = 0, missing: [String] = []
            for (n, a) in before.enumerated() {
                webWork = "Checking story \(n + 1) of \(before.count)…"
                var slug = PolyWeb.slug(in: a.source)
                if slug == nil { slug = try? await PolyWeb.slug(forHeadline: a.headline) }
                guard let slug, let story = try? await PolyWeb.story(slug: slug) else {
                    missing.append(a.plainHeadline.isEmpty ? "Untitled" : a.plainHeadline); continue
                }
                let photos = await PolyWeb.download(story.photos, into: Self.mediaDir, keeping: a.photos)
                guard let i = issue.articles.firstIndex(where: { $0.id == a.id }) else { continue }   // deleted meanwhile
                var b = issue.articles[i]
                if !story.body.isEmpty { b.body = story.body }
                if !story.author.isEmpty { b.author = story.author; b.authorTitle = story.authorTitle }
                b.source = story.page.absoluteString
                if b.kicker.isEmpty { b.kicker = story.kicker }
                b.photos = b.photos.map { p in photos.first { $0.id == p.id } ?? p }
                let added = photos.filter { p in !b.photos.contains { $0.id == p.id } }
                b.photos += added
                newPhotos += added.count
                if b != issue.articles[i] {
                    b.updated = Date()
                    let was = issue.articles[i]
                    issue.articles[i] = b
                    reflowArt(for: was, now: b)
                    changed.append(b.plainHeadline)
                } else { same += 1 }
            }
            if !changed.isEmpty {
                let now = issue.articles
                registerArticlesUndo(before, now, "Update from Website")
                scheduleSave()
            }
            var lines: [String] = []
            lines.append(changed.isEmpty ? "No story changed." : "Updated \(changed.count) \(changed.count == 1 ? "story" : "stories").")
            if newPhotos > 0 { lines.append("Downloaded \(newPhotos) new \(newPhotos == 1 ? "photo" : "photos").") }
            if same > 0 { lines.append("\(same) already matched the website.") }
            if !missing.isEmpty { lines.append("Not found on poly.rpi.edu: " + missing.joined(separator: "; ") + ".") }
            tell("Update from Website", lines.joined(separator: " "))
        }
    }

    private func registerArticlesUndo(_ before: [Article], _ after: [Article], _ name: String) {
        undoManager?.registerUndo(withTarget: self) { s in
            s.issue.articles = before
            s.registerArticlesUndo(after, before, name)
            s.scheduleSave()
        }
        undoManager?.setActionName(name)
    }

    private func tell(_ title: String, _ info: Any) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (info as? LocalizedError)?.errorDescription ?? (info as? Error)?.localizedDescription ?? "\(info)"
        alert.runModal()
    }

    func delete(_ id: Article.ID) {
        if issue.extras.contains(where: { $0.id == id }) { removeExtra(id); return }
        guard let i = issue.articles.firstIndex(where: { $0.id == id }) else { return }
        issue.articles.remove(at: i)
        dropFills(article: id)
        if selection == id { selection = issue.articles.indices.contains(i) ? issue.articles[i].id : issue.articles.last?.id }
        scheduleSave()
    }

    /// Copy a dropped or chosen image into the app's media folder and return the stored path.
    func importImage(_ url: URL) -> String? {
        let dest = Self.mediaDir.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: dest); return dest.path } catch { return nil }
    }

    static func imageURL(for photo: String?) -> URL? {
        guard let photo else { return nil }
        if photo.hasPrefix("seed:") {
            return Bundle.main.resourceURL?.appendingPathComponent("SeedMedia").appendingPathComponent(String(photo.dropFirst(5)))
        }
        return URL(fileURLWithPath: photo)
    }

    // MARK: layout

    @ObservationIgnored let composer = Composer()
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var editing = false
    var editingNow: Bool { editing }
    @ObservationIgnored private var editBefore: IssueLayout?
    var zoom: CGFloat = UserDefaults.standard.object(forKey: "zoom") as? CGFloat ?? 0.62 {
        didSet { UserDefaults.standard.set(zoom, forKey: "zoom") }
    }
    var showGuides = UserDefaults.standard.bool(forKey: "showGuides") {
        didSet { UserDefaults.standard.set(showGuides, forKey: "showGuides") }
    }
    var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    /// The selected item when one is selected; nil when nothing is, or when several are (then `selectionSet` holds
    /// them: Store+MultiSelect.swift). Setting it selects that one item alone.
    var canvasSelection: LayoutSelection? {
        didSet { if !keepsSelectionSet { let s: Set<LayoutSelection> = canvasSelection.map { [$0] } ?? []; if selectionSet != s { selectionSet = s } } }
    }
    /// Everything selected on the canvas (phase 7): one item, or several on one page.
    var selectionSet: Set<LayoutSelection> = []
    @ObservationIgnored var keepsSelectionSet = false
    /// A placed component being edited in place (Store+InPlace.swift).
    var inPlace: InPlaceEdit?
    /// The pointer gesture on the canvas (`Store+Pointer.swift`), and a switch the gesture throws while ⌘ is held.
    var pointer = PointerState()
    @ObservationIgnored var snapOff = false
    /// Where the pointer is over a page, kept by the page's own view; the edge of the selected item under it,
    /// which the handles show and the cursor follows; and whether an edge is being pulled right now.
    @ObservationIgnored var hover: (page: Int, point: CGPoint)?
    var hoverZone: ResizeZone?
    var resizing = false
    var focusedPage: Int?
    var activeGuides: (page: Int, guides: [Guide])?
    /// What's being dragged on the canvas, and whether the pointer has left it for the inspector.
    var dragging: LayoutSelection?
    var dragOutside = false
    /// What's being dragged out of the inspector, the page it hovers, and where it would land there.
    var inspectorDrag: DragItem?
    var dropTarget: Int?
    var dropPreview: CGRect?
    /// While a block's top or bottom edge is pulled: where that edge lands for a comfortable fit (a band) and
    /// for house style (a line), in page points.
    var fitBand: (page: Int, band: CGRect, house: CGFloat)?
    var canvasViewport = CGSize(width: 1000, height: 800)
    @ObservationIgnored private var lastJump: (story: Article.ID, index: Int)?
    @ObservationIgnored private var previewCache: (key: String, rect: CGRect?)?

    func zoomToFit() { zoom = ((canvasViewport.width - 96) / HouseStyle.page.width).clamped(0.25, 2) }

    /// The edge or corner of the selected item under a point on a page, in page points (`CanvasHitTest`).
    func zone(at p: CGPoint, on page: Int) -> ResizeZone? { hit(at: p, on: page).edge }

    /// Where the body starts in every block of a page, bylines held level with their neighbours' included.
    func bodyTops(on page: Int) -> [StoryBlock.ID: CGFloat] {
        guard let p = issue.layout?.pages[safe: page] else { return [:] }
        let articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let aligned = composer.alignedBodyTops(p, articles: articles, composer.obstacles(p, articles: articles))
        var out: [StoryBlock.ID: CGFloat] = [:]
        for b in p.stories {
            guard let a = articles[b.article] else { continue }
            out[b.id] = composer.blockGeometry(a, frame: b.frame.rect, columns: b.columns, headlineSize: b.headlineSize, avoid: [],
                                               bylineColumns: b.bylineColumns, bodyTop: aligned[b.id], draw: false).bodyTop
        }
        return out
    }

    /// Whether a point on a page is over a block or a picture: something that can be picked up (`CanvasHitTest`).
    func itemUnder(_ p: CGPoint, on page: Int) -> Bool { hit(at: p, on: page).isItem }

    var selectedInset: Inset.ID? {
        get { if case .inset(let id) = canvasSelection { id } else { nil } }
        set { canvasSelection = newValue.map { .inset($0) } }
    }
    var selectedBlock: StoryBlock.ID? {
        get { if case .block(let id) = canvasSelection { id } else { nil } }
        set { canvasSelection = newValue.map { .block($0) } }
    }

    /// The issue set in type, page by page, every story exactly fit: for edits that act on the result, and export.
    /// Unchanged pages come from the composer's cache.
    var composedPages: [ComposedPage] { composer.compose(issue) }

    /// The issue as the canvas shows it. In the app this never waits on a copyfit search: a story whose fit isn't
    /// known yet is set at its last one and its exact fit swapped in when the background worker has it.
    var displayPages: [ComposedPage] { _ = fitsArrived; return composer.compose(issue, exact: false) }

    /// Bumped when background fits come in, so whatever drew `displayPages` draws again.
    var fitsArrived = 0

    /// The stories or their order changed since the paper was generated.
    var layoutIsStale: Bool {
        guard let l = issue.layout else { return false }
        return l.basis != issue.articles.map(\.id)
    }

    var grid: Grid { issue.layout?.grid ?? Grid(columns: 3) }

    enum Placement { case frontLead, front, inside, skipped }

    /// Where each story lands by rank: the top two lead the front page, the rest go inside.
    var placements: [Article.ID: Placement] {
        var out: [Article.ID: Placement] = [:]
        var rank = 0
        for a in issue.articles {
            guard a.body.contains(where: { !$0.trimmed.isEmpty }) else { out[a.id] = .skipped; continue }
            out[a.id] = rank == 0 ? .frontLead : rank == 1 ? .front : .inside
            rank += 1
        }
        return out
    }

    func go(to stage: Stage) {
        if stage == .pages, issue.paperNotGenerated { generate(); return }
        issue.stage = stage
        scheduleSave()
    }

    /// The next step: done adding stories, then generate the paper.
    func advance() {
        switch issue.stage {
        case .stories: go(to: .priority)
        case .priority: generate()
        case .pages: break
        }
    }

    func generate() {
        guard !isEditingTemplate else { return }               // a template has no stories to lay out
        edit("Generate Paper") {
            issue.generateLayout(composer: composer, seed: UInt64.random(in: 1...UInt64.max))
        }
        issue.stage = .pages
        canvasSelection = nil
        focusedPage = 0
    }

    /// Re-plan one inside page with the same stories.
    func shufflePage(_ index: Int) {
        guard var layout = issue.layout, layout.pages.indices.contains(index), !layout.pages[index].isFront else { return }
        let composed = composedPages
        guard composed.indices.contains(index) else { return }
        var previous: [Article.ID: Int] = [:]
        for (i, p) in layout.pages.enumerated() where i < index {
            for b in p.readingOrder { previous[b.article] = i + 1 }
        }
        let gen = LayoutGenerator(issue: issue, composer: composer, seed: UInt64.random(in: 1...UInt64.max), columns: layout.columns)
        guard let page = gen.reshuffle(layout.pages[index], number: index + 1, incoming: composed[index].incoming, continuedFrom: previous) else {
            NSSound.beep(); return
        }
        layout.pages[index] = page
        edit("Shuffle Page") { issue.layout = layout }
        canvasSelection = nil
    }

    // MARK: undo

    /// Wrap a change to the layout so ⌘Z puts it back.
    func edit(_ name: String, _ change: () -> Void) {
        let before = issue.layout
        change()
        guard before != issue.layout else { return }
        registerUndo(before, name)
        scheduleSave()
    }

    /// A drag: one undo step for the whole gesture.
    func beginEdit() {
        // a session the canvas never closed (its drag end was lost) is closed first, so this one starts clean
        if editing, !Composer.pointerDown() { recoverLostDrag() }
        guard !editing else { return }
        editing = true
        editBefore = issue.layout
        composer.deferFits = true
    }

    func endEdit(_ name: String) {
        activeGuides = nil
        fitBand = nil
        composer.deferFits = false
        guard editing else { return }
        editing = false
        guard editBefore != issue.layout else { return }
        // one undo step per gesture, even when two gestures close in one turn of the run loop (a lost drag closed
        // by the next press, or events fed in a row): the step is a group of its own, never merged by the event
        // grouping with what was registered before or after it (IB-16)
        if let um = undoManager, !um.isUndoing, !um.isRedoing {
            if um.groupsByEvent, um.groupingLevel == 1 { um.endUndoGrouping() }    // close the event's open group, as undo() does
            um.beginUndoGrouping()
            registerUndo(editBefore, name)
            um.endUndoGrouping()
        } else {
            registerUndo(editBefore, name)
        }
        scheduleSave()
    }

    /// A drag whose end the canvas never heard about: close its edit session as the end would have, so later
    /// drags get the quick fits again and the next undo step starts from here, not from before the lost drag.
    func recoverLostDrag() { pointerCancelled() }

    private func registerUndo(_ before: IssueLayout?, _ name: String) {
        undoManager?.registerUndo(withTarget: self) { s in
            let now = s.issue.layout
            s.issue.layout = before
            s.pruneSelection()
            s.registerUndo(now, name)
            s.scheduleSave()
        }
        undoManager?.setActionName(name)
    }

    // MARK: snapping

    /// Edges a frame may move while it's dragged.
    struct Edges: OptionSet { let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
        static let all: Edges = [.left, .right, .top, .bottom]
    }

    /// Pull `r` onto the column grid, the margins and the edges of what's already on the page.
    /// With `move` the whole frame shifts; otherwise only the edges in `edges` are adjusted.
    /// The stroke a picture is drawn with, inside its frame: what has to land on a rule for the two to be one line.
    func outline(of inset: Inset) -> CGFloat {
        switch inset.kind {
        case .photo: HouseStyle.photoOutline
        case .pullQuote: HouseStyle.pullQuoteRule
        case .extra: 0
        }
    }

    /// `outline` is the stroke of the thing being dragged, stroked inside its frame: a frame edge snapped to a
    /// rule is offset by half of it, so the stroke's centre sits on the rule's and the two read as one line.
    func snap(_ r: CGRect, page: Int, excluding: Set<UUID> = [], edges: Edges = .all, move: Bool = true,
              alsoTops: [CGFloat] = [], alsoBottoms: [CGFloat] = [], outline: CGFloat = 0) -> (rect: CGRect, guides: [Guide]) {
        if snapOff { return (r, []) }                                       // ⌘ held: nothing pulls
        let g = grid
        let threshold = (9 / zoom).clamped(4, 18)
        let top = (issue.layout?.pages[safe: page]?.isFront ?? false) ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        var lefts = (0..<g.columns).map { g.x($0) }, rights = (0..<g.columns).map { g.x($0) + g.colWidth }
        var tops: [CGFloat] = alsoTops, bottoms: [CGFloat] = alsoBottoms
        // the edges of the live page pull from further away than anything else, so a frame put near a margin lands on it
        var strongTops: [CGFloat] = [top], strongBottoms: [CGFloat] = [HouseStyle.bottom]
        // the rules around a byline come first: within reach, a frame's edge lands on one whatever else is nearer
        var ruleTops: [CGFloat] = [], ruleBottoms: [CGFloat] = []
        let strongLefts: [CGFloat] = [HouseStyle.margin], strongRights: [CGFloat] = [HouseStyle.margin + HouseStyle.liveWidth]
        // a picture's top sits a clearance under the line above it: the line grid of the story it lies in
        let picture = (issue.layout?.pages[safe: page]?.insets ?? []).contains { excluding.contains($0.id) && $0.kind != .pullQuote }
        if picture, let (bodyTop, pitch) = lineGrid(under: r, on: page) {
            var y = bodyTop + Composer.clearAbovePicture
            while y < HouseStyle.bottom { strongTops.append(y); y += pitch }
        }
        if let p = issue.layout?.pages[safe: page] {
            // a story dragged beside another snaps level with its top first, so the two stories' kickers or
            // headlines (and then their bylines) line up across the page
            let draggingStory = p.stories.contains { excluding.contains($0.id) }
            for b in p.stories where !excluding.contains(b.id) {
                let f = b.frame.rect
                lefts += [f.minX, f.maxX + HouseStyle.gutter]; rights += [f.maxX, f.minX - HouseStyle.gutter]
                if draggingStory { strongTops.append(f.minY) } else { tops += [f.minY] }
                bottoms += [f.maxY]
                // the house gap to the story above or below is the place to land: it pulls from further away
                strongTops.append(f.maxY + HouseStyle.moduleGap); strongBottoms.append(f.minY - HouseStyle.moduleGap)
            }
            for i in p.insets where !excluding.contains(i.id) {
                let f = i.frame.rect
                lefts += [f.minX, f.maxX + HouseStyle.gutter]; rights += [f.maxX, f.minX - HouseStyle.gutter]
                tops += [f.minY, f.maxY]; bottoms += [f.maxY, f.minY]
            }
            // the lines inside a story: the byline's rules and where the body starts, so a picture can sit on them
            let aligned = composer.alignedBodyTops(p, articles: Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                                   composer.obstacles(p, articles: Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })))
            for b in p.stories where !excluding.contains(b.id) {
                guard let a = article(b.article) else { continue }
                let g = composer.blockGeometry(a, frame: b.frame.rect, columns: b.columns, headlineSize: b.headlineSize, avoid: [],
                                               bylineColumns: b.bylineColumns, bodyTop: aligned[b.id], draw: false)
                if let by = g.byline {
                    ruleTops += [by.minY - outline / 2, by.maxY - outline / 2]
                    ruleBottoms += [by.minY + outline / 2, by.maxY + outline / 2]
                }
                if outline == 0 || g.byline == nil { strongTops.append(g.bodyTop); strongBottoms.append(g.bodyTop) }
            }
        }
        func nearest(_ v: CGFloat, _ cands: [CGFloat], _ strong: [CGFloat] = [], rules: [CGFloat] = []) -> CGFloat? {
            if let r = rules.min(by: { abs($0 - v) < abs($1 - v) }), abs(r - v) < threshold * 2.5 { return r }
            let weak = cands.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) < threshold ? $0 : nil }
            let hard = strong.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) < threshold * 2.5 ? $0 : nil }
            switch (weak, hard) {
            case (nil, nil): return nil
            case (let w?, nil): return w
            case (nil, let h?): return h
            case (let w?, let h?): return abs(w - v) <= abs(h - v) ? w : h
            }
        }
        var out = r
        var guides: [Guide] = []
        if move {
            let dl = nearest(r.minX, lefts, strongLefts).map { $0 - r.minX }, dr = nearest(r.maxX, rights, strongRights).map { $0 - r.maxX }
            if let d = [dl, dr].compactMap({ $0 }).min(by: { abs($0) < abs($1) }) {
                out.origin.x += d
                guides.append(Guide(axis: .x, at: d == dl ? out.minX : out.maxX))
            }
            let dt = nearest(r.minY, tops, strongTops, rules: ruleTops).map { $0 - r.minY }, db = nearest(r.maxY, bottoms, strongBottoms, rules: ruleBottoms).map { $0 - r.maxY }
            // an edge on a byline rule wins over the other edge's nearer snap
            let onRule = { (v: CGFloat, rules: [CGFloat]) in rules.contains { abs($0 - v) < threshold * 2.5 } }
            let preferred: CGFloat? = onRule(r.minY, ruleTops) ? dt : onRule(r.maxY, ruleBottoms) ? db : nil
            if let d = preferred ?? [dt, db].compactMap({ $0 }).min(by: { abs($0) < abs($1) }) {
                out.origin.y += d
                guides.append(Guide(axis: .y, at: d == dt ? out.minY : out.maxY))
            }
        } else {
            if edges.contains(.left), let x = nearest(r.minX, lefts, strongLefts) { out.origin.x = x; out.size.width = r.maxX - x; guides.append(Guide(axis: .x, at: x)) }
            if edges.contains(.right), let x = nearest(r.maxX, rights, strongRights) { out.size.width = x - out.minX; guides.append(Guide(axis: .x, at: x)) }
            if edges.contains(.top), let y = nearest(r.minY, tops, strongTops, rules: ruleTops) { out.origin.y = y; out.size.height = r.maxY - y; guides.append(Guide(axis: .y, at: y)) }
            if edges.contains(.bottom), let y = nearest(r.maxY, bottoms, strongBottoms, rules: ruleBottoms) { out.size.height = y - out.minY; guides.append(Guide(axis: .y, at: y)) }
        }
        return (out, guides)
    }

    /// The line grid under a frame: where the body starts in the story block it lies in (most of it), and that
    /// story's leading.
    func lineGrid(under r: CGRect, on page: Int) -> (bodyTop: CGFloat, pitch: CGFloat)? {
        guard let p = issue.layout?.pages[safe: page] else { return nil }
        func overlap(_ b: StoryBlock) -> CGFloat { let i = b.frame.rect.intersection(r); return i.isNull ? 0 : i.width * i.height }
        let host = p.stories.max { overlap($0) < overlap($1) }
        guard let b = host, overlap(b) > 0, let a = article(b.article), let top = bodyTops(on: page)[b.id] else { return nil }
        return (top, composer.settings[a.id]?.leading ?? HouseStyle.leading)
    }

    /// A picture's frame trimmed onto the line grid of the story it lies in (see `Composer.onLineGrid`).
    func onLineGrid(_ inset: Inset, frame r: CGRect, on page: Int, anchorBottom: Bool = false) -> CGRect {
        guard inset.kind == .photo || inset.kind == .extra, let (bodyTop, pitch) = lineGrid(under: r, on: page) else { return r }
        let caption = composer.geometry(inset, article(inset.article), extra(inset.extra)).map { $0.full.height - $0.picture.height } ?? 0
        return Composer.onLineGrid(r, caption: caption, bodyTop: bodyTop, pitch: pitch, anchorBottom: anchorBottom)
    }

    /// The nearest column a frame `span` columns wide can start in, for a pointer at `x`.
    func column(nearest x: CGFloat, span: Int) -> Int {
        let g = grid
        let last = max(0, g.columns - span.clamped(1, g.columns))
        return (0...last).min { abs(g.x($0) - x) < abs(g.x($1) - x) } ?? 0
    }

    // MARK: resizing by the edges

    /// A story block pulled by one of its edges: columns and neighbours snap, the frame stays at least a column wide
    /// and on the page. With `fitHeight`, the pulled edge also snaps where the story would fit at house style.
    func resizedBlock(_ id: StoryBlock.ID, start: CGRect, zone: ResizeZone, dx: CGFloat, dy: CGFloat, page: Int, fitHeight: CGFloat? = nil) -> (rect: CGRect, guides: [Guide]) {
        let r = ResizeMath.resize(start, zone, dx: dx, dy: dy, min: CGSize(width: grid.colWidth, height: 40))
        var alsoTops: [CGFloat] = [], alsoBottoms: [CGFloat] = []
        if let h = fitHeight {
            if zone.edges.contains(.bottom) { alsoBottoms = [start.minY + h] }
            if zone.edges.contains(.top) { alsoTops = [start.maxY - h] }
        }
        // the body's line grid: an edge lands where a line ends, so the block holds whole lines and no slack
        if zone.vertical, let (_, b) = block(id), let a = article(b.article) {
            let g = composer.blockGeometry(a, frame: start, columns: b.columns, headlineSize: b.headlineSize, avoid: [], bylineColumns: b.bylineColumns, draw: false)
            let pitch = composer.settings[a.id]?.leading ?? HouseStyle.leading
            if zone.edges.contains(.bottom) {
                var y = g.bodyTop + pitch
                while y <= HouseStyle.page.height { alsoBottoms.append(y); y += pitch }
            }
            if zone.edges.contains(.top) {
                let head = g.bodyTop - start.minY
                var y = start.maxY - pitch - head
                while y >= 0 { alsoTops.append(y); y -= pitch }
            }
        }
        let (snapped, guides) = snap(r, page: page, excluding: [id], edges: zone.edges, move: false, alsoTops: alsoTops, alsoBottoms: alsoBottoms)
        return (withinPage(snapped), guides)
    }

    /// Pull the edges of a frame back inside the page, without moving the ones already there.
    private func withinPage(_ r: CGRect) -> CGRect {
        let page = CGRect(origin: .zero, size: HouseStyle.page)
        let i = r.intersection(page)
        return i.isNull || i.isEmpty ? r : i
    }

    /// A picture pulled by one of its edges. Pictures keep their proportions, so the width is what's really being
    /// set (pulling the top or bottom sets it through the height) and it snaps to the columns; hold ⌥ to crop
    /// freely. A pull quote's height follows its text, so only its width moves.
    func resizedInset(_ inset: Inset, start: CGRect, zone: ResizeZone, dx: CGFloat, dy: CGFloat, free: Bool, page: Int) -> (rect: CGRect, guides: [Guide]) {
        if inset.kind == .pullQuote {
            guard let z = zone.widthOnly else { return (start, []) }
            let r = ResizeMath.resize(start, z, dx: dx, dy: 0, min: CGSize(width: 60, height: start.height))
            let (snapped, guides) = snap(r, page: page, excluding: [inset.id], edges: z.edges, move: false, outline: outline(of: inset))
            return (withinPage(snapped), guides)
        }
        let pulled = ResizeMath.resize(start, zone, dx: dx, dy: dy, min: CGSize(width: 60, height: 40))
        if free {
            let (snapped, guides) = snap(pulled, page: page, excluding: [inset.id], edges: zone.edges, move: false)
            return (withinPage(snapped), guides)
        }
        guard start.width > 0, start.height > 0 else { return (pulled, []) }
        let aspect = start.width / start.height
        let anchorLeft = !zone.edges.contains(.left), anchorTop = !zone.edges.contains(.top)
        var w = zone.horizontal ? pulled.width : max(60, pulled.height * aspect)
        // the frame can't leave the page on the side that moves
        w = min(w, anchorLeft ? HouseStyle.page.width - start.minX : start.maxX)
        let candidate = CGRect(x: anchorLeft ? start.minX : start.maxX - w, y: start.minY, width: w, height: start.height)
        let (snapped, guides) = snap(candidate, page: page, excluding: [inset.id], edges: anchorLeft ? .right : .left, move: false, outline: outline(of: inset))
        w = snapped.width
        var h = w / aspect
        if h > (anchorTop ? HouseStyle.page.height - start.minY : start.maxY) {       // nor top or bottom
            h = anchorTop ? HouseStyle.page.height - start.minY : start.maxY
            w = h * aspect
        }
        let sized = CGRect(x: anchorLeft ? start.minX : start.maxX - w, y: anchorTop ? start.minY : start.maxY - h, width: w, height: h)
        return (snapOff ? sized : onLineGrid(inset, frame: sized, on: page, anchorBottom: !anchorTop), guides.filter { $0.axis == .x })
    }

    /// Pull a frame onto the column grid when it comes close, and keep it on the page.
    func snap(_ r: CGRect) -> CGRect {
        var r = grid.snap(r)
        r.origin.x = r.origin.x.clamped(0, HouseStyle.page.width - r.width)
        return r
    }

    func onPage(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = r.origin.x.clamped(0, max(0, HouseStyle.page.width - r.width))
        r.origin.y = r.origin.y.clamped(0, max(0, HouseStyle.page.height - r.height))
        return r
    }

    /// How many grid columns a width covers, nearest.
    func columns(for width: CGFloat) -> Int {
        (1...grid.columns).min { abs(grid.span($0) - width) < abs(grid.span($1) - width) } ?? 1
    }

    // MARK: insets

    /// Where a cropped picture is looking: 0…1 on each axis (see `Inset.focus`).
    func setInsetFocus(_ id: Inset.ID, page: Int, focus: CGPoint) {
        guard let k = issue.layout?.pages[safe: page]?.insets.firstIndex(where: { $0.id == id }) else { return }
        issue.layout!.pages[page].insets[k].focus = focus
        if !editing { scheduleSave() }
    }

    /// How much of a picture its frame hides, in page points, on each axis (one of them is always 0).
    func hidden(in inset: Inset) -> CGSize {
        guard let img = picture(for: inset), img.size.width > 0, img.size.height > 0 else { return .zero }
        let r = inset.frame.rect
        let scale = max(r.width / img.size.width, r.height / img.size.height)
        return CGSize(width: max(0, img.size.width * scale - r.width), height: max(0, img.size.height * scale - r.height))
    }

    func setInsetFrame(_ id: Inset.ID, page: Int, frame: CGRect) {
        guard let k = issue.layout?.pages[safe: page]?.insets.firstIndex(where: { $0.id == id }) else { return }
        issue.layout!.pages[page].insets[k].frame = Box(frame)
        if !editing { scheduleSave() }
    }

    /// Move a picture to another page; the text there wraps around it.
    func moveInset(_ id: Inset.ID, from: Int, to: Int, frame: CGRect) {
        guard var layout = issue.layout, layout.pages.indices.contains(to),
              let k = layout.pages[from].insets.firstIndex(where: { $0.id == id }) else { return }
        var inset = layout.pages[from].insets.remove(at: k)
        inset.frame = Box(frame)
        layout.pages[to].insets.append(inset)
        issue.layout = layout
        focusedPage = to
        if !editing { scheduleSave() }
    }

    func removeInset(_ id: Inset.ID) {
        edit("Remove Photo") {
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].insets.removeAll { $0.id == id } }
        }
        if selectedInset == id { canvasSelection = nil }
    }

    func picture(for inset: Inset) -> NSImage? {
        if inset.kind == .extra { return extra(inset.extra).flatMap { composer.image($0.path) } }
        guard let a = article(inset.article), let p = a.photos.first(where: { $0.id == inset.photo }) else { return nil }
        return composer.image(p.path)
    }

    /// Where every story's photos and pull quotes sit: photos by their id, quotes by their story.
    func artPlacements() -> (photos: [Photo.ID: (page: Int, id: Inset.ID)], quotes: [Article.ID: (page: Int, id: Inset.ID)]) {
        var photos: [Photo.ID: (page: Int, id: Inset.ID)] = [:], quotes: [Article.ID: (page: Int, id: Inset.ID)] = [:]
        for (i, p) in (issue.layout?.pages ?? []).enumerated() {
            for inset in p.insets {
                if inset.kind == .photo, let ph = inset.photo { photos[ph] = (i, inset.id) }
                if inset.kind == .pullQuote, let a = inset.article { quotes[a] = (i, inset.id) }
            }
        }
        return (photos, quotes)
    }

    /// Where one of a story's photos goes: at `point` (its top-left corner, on the nearest column), else the house
    /// spot in the story's block there (right-hand columns under the headline), else the biggest free space.
    func photoFrame(_ p: Photo, of a: Article, on page: Int, at point: CGPoint?, in block: StoryBlock.ID? = nil) -> CGRect? {
        guard let pl = issue.layout?.pages[safe: page] else { return nil }
        let g = grid, aspect = composer.aspect(p)
        let span = min(2, g.columns)
        let top = pl.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        if let point {
            let w = g.span(span)
            let h = w / aspect
            let r = CGRect(x: g.x(column(nearest: point.x, span: span)), y: point.y.clamped(top, max(top, HouseStyle.bottom - h)), width: w, height: h)
            return onPage(snap(r, page: page, edges: [.top], move: false, outline: HouseStyle.photoOutline).rect)
        }
        let home = block.flatMap { id in pl.stories.first { $0.id == id } } ?? pl.readingOrder.first { $0.article == a.id }
        if let b = home {
            let f = b.frame.rect
            let w = g.span(max(1, b.columns - 1))
            let hh = composer.headlineHeight(a, width: f.width, size: b.headlineSize)
            let h = (w / aspect).clamped(0.42 * w, max(60, min(0.85 * w, f.height * 0.5)))
            let r = CGRect(x: f.maxX - w, y: f.minY + hh + (hh > 0 ? HouseStyle.headlineGap : 0) + 4, width: w, height: h)
            let caption = Composer.caption(p, width: w).map { composer.height(of: $0, width: w) + 4 } ?? 0
            let g0 = composer.blockGeometry(a, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: [], bylineColumns: b.bylineColumns, draw: false)
            return Composer.onLineGrid(r, caption: caption, bodyTop: g0.bodyTop, pitch: composer.settings[a.id]?.leading ?? HouseStyle.leading)
        }
        if let free = freeSpace(on: page) {
            let w = min(free.width, g.span(span))
            return CGRect(x: free.minX, y: free.minY, width: w, height: min(w / aspect, free.height))
        }
        let w = g.span(span)
        return CGRect(x: HouseStyle.margin, y: HouseStyle.bottom - w / aspect, width: w, height: w / aspect)
    }

    /// Where a story's pull quote goes: at `point`, else a column in the middle of its block, else free space.
    func quoteFrame(of a: Article, on page: Int, at point: CGPoint?, in block: StoryBlock.ID? = nil) -> CGRect? {
        let q = a.pullQuote.trimmed
        guard !q.isEmpty, let pl = issue.layout?.pages[safe: page] else { return nil }
        let g = grid, w = g.colWidth
        let h = composer.height(of: Composer.pullQuote(q, width: w), width: w - 20) + 20
        let top = pl.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        if let point {
            let r = CGRect(x: g.x(column(nearest: point.x, span: 1)), y: point.y.clamped(top, max(top, HouseStyle.bottom - h)), width: w, height: h)
            return onPage(snap(r, page: page, edges: [.top], move: false, outline: HouseStyle.pullQuoteRule).rect)
        }
        let home = block.flatMap { id in pl.stories.first { $0.id == id } } ?? pl.readingOrder.first { $0.article == a.id }
        if let b = home {
            let f = b.frame.rect
            let hh = composer.headlineHeight(a, width: f.width, size: b.headlineSize)
            let bodyTop = f.minY + hh + (hh > 0 ? 7 : 0)
            let col = b.columns >= 3 ? 1 : max(0, b.columns - 1)
            let y = bodyTop + ((f.maxY - bodyTop) * 0.45 - h / 2).clamped(0, max(0, f.maxY - bodyTop - h))
            return CGRect(x: f.minX + CGFloat(col) * (w + HouseStyle.gutter), y: y, width: w, height: h)
        }
        if let free = freeSpace(on: page) { return CGRect(x: free.minX, y: free.minY, width: w, height: h) }
        return CGRect(x: HouseStyle.margin, y: HouseStyle.bottom - h, width: w, height: h)
    }

    /// Put one of a story's photos on a page. A photo already placed moves rather than running twice.
    @discardableResult
    func placePhoto(_ photo: Photo.ID, of article: Article.ID, on page: Int, at point: CGPoint? = nil, in block: StoryBlock.ID? = nil) -> Inset.ID? {
        guard let a = self.article(article), let p = a.photos.first(where: { $0.id == photo }),
              let r = photoFrame(p, of: a, on: page, at: point, in: block) else { return nil }
        let moving = artPlacements().photos[photo] != nil
        var id: Inset.ID?
        edit(moving ? "Move Photo" : "Place Photo") {
            id = insertPhoto(photo, of: article, on: page, frame: r)
            grow(home(for: article, on: page, around: r, or: point == nil ? block : nil), on: page, article: a)
        }
        canvasSelection = id.map { .inset($0) }
        focusedPage = page
        return id
    }

    /// The layout change behind `placePhoto`, for callers that are already inside an edit.
    @discardableResult
    private func insertPhoto(_ photo: Photo.ID, of article: Article.ID, on page: Int, frame r: CGRect) -> Inset.ID {
        var inset = Inset(kind: .photo, article: article, photo: photo, frame: Box(r))
        if let existing = artPlacements().photos[photo] {
            inset.id = existing.id
            issue.layout!.pages[existing.page].insets.removeAll { $0.id == existing.id }
        }
        issue.layout!.pages[page].insets.append(inset)
        return inset.id
    }

    @discardableResult
    private func insertQuote(of article: Article.ID, on page: Int, frame r: CGRect) -> Inset.ID {
        var inset = Inset(kind: .pullQuote, article: article, photo: nil, frame: Box(r))
        if let existing = artPlacements().quotes[article] {
            inset.id = existing.id
            issue.layout!.pages[existing.page].insets.removeAll { $0.id == existing.id }
        }
        issue.layout!.pages[page].insets.append(inset)
        return inset.id
    }

    /// The story's block that new art landed in: the one asked for, else the one under the art's centre.
    private func home(for article: Article.ID, on page: Int, around r: CGRect, or block: StoryBlock.ID?) -> StoryBlock.ID? {
        guard let pl = issue.layout?.pages[safe: page] else { return nil }
        if let block, pl.stories.contains(where: { $0.id == block }) { return block }
        return pl.stories.last { $0.article == article && $0.frame.rect.contains(CGPoint(x: r.midX, y: r.midY)) }?.id
    }

    /// A block that was sized to its text has art in it now: let it run down to take the displaced lines, as far as
    /// whatever is below allows. It never shrinks.
    private func grow(_ id: StoryBlock.ID?, on page: Int, article a: Article) {
        guard let id, let b = issue.layout?.pages[safe: page]?.stories.first(where: { $0.id == id }) else { return }
        let want = fitted(b, on: page, article: a)
        guard want.height > b.frame.h + 1 else { return }
        let keep = Set(insets(with: b, on: page).map(\.id)).union([id])
        let h = min(want.height, floor(below: b.frame.rect, on: page, excluding: keep) - b.frame.y)
        if h > b.frame.h + 1 { setBlockFrame(id, page: page, frame: CGRect(x: b.frame.x, y: b.frame.y, width: b.frame.w, height: h)) }
    }

    /// Put a story's pull quote on a page; one already placed moves.
    @discardableResult
    func placePullQuote(of article: Article.ID, on page: Int, at point: CGPoint? = nil, in block: StoryBlock.ID? = nil) -> Inset.ID? {
        guard let a = self.article(article), let r = quoteFrame(of: a, on: page, at: point, in: block) else { return nil }
        let moving = artPlacements().quotes[article] != nil
        var id: Inset.ID?
        edit(moving ? "Move Pull Quote" : "Place Pull Quote") {
            id = insertQuote(of: article, on: page, frame: r)
            grow(home(for: article, on: page, around: r, or: point == nil ? block : nil), on: page, article: a)
        }
        canvasSelection = id.map { .inset($0) }
        focusedPage = page
        return id
    }

    // MARK: dropping onto a page

    /// Where a dragged item would land if let go at `point` (its top-left corner), in page points.
    func frame(for item: DragItem, on page: Int, at point: CGPoint?) -> CGRect? {
        let key = "\(item.string)|\(page)|\(point.map { "\(Int($0.x / 4))|\(Int($0.y / 4))" } ?? "-")|\(issue.layout?.hashValue ?? 0)|\(snapOff)"
        if let c = previewCache, c.key == key { return c.rect }
        // over a component's frame that takes it, the item fills the frame: the preview is the frame (phase 5)
        if let point, let t = frameTarget(at: point, on: page, for: item) { previewCache = (key, t.rect); return t.rect }
        let rect: CGRect?
        switch item {
        case .story(let id):
            rect = article(id).flatMap { blockFrame(for: $0, on: page, at: point) }
        case .photo(let aid, let pid):
            rect = article(aid).flatMap { a in a.photos.first { $0.id == pid }.flatMap { photoFrame($0, of: a, on: page, at: point) } }
        case .quote(let id):
            rect = article(id).flatMap { quoteFrame(of: $0, on: page, at: point) }
        case .extra(let id):
            rect = extra(id).flatMap { extraFrame($0, on: page, at: point) }
        case .component(let id, let n):
            rect = componentFrame(id, version: n, on: page, at: point)
        }
        previewCache = (key, rect)
        return rect
    }

    /// What a dragged item is called, for the preview over the page.
    func name(of item: DragItem) -> String {
        switch item {
        case .story(let id): article(id)?.plainHeadline ?? "Story"
        case .photo(let a, let p): article(a)?.photos.first { $0.id == p }.map { $0.caption.isEmpty ? "Photo" : String($0.caption.prefix(40)) } ?? "Photo"
        case .quote: "Pull quote"
        case .extra(let id): extra(id).map { $0.title.isEmpty ? $0.kind.rawValue : $0.title } ?? "Item"
        case .component(let id, let n): catalogComponent(id).map { "\($0.name) v\(n)" } ?? "Component"
        }
    }

    /// Put a dragged item on a page, at `point` or where it belongs.
    @discardableResult
    func place(_ item: DragItem, on page: Int, at point: CGPoint? = nil) -> Bool {
        // dropped on a component's frame that takes it: the frame (or its linked group) is filled
        if let point, let t = frameTarget(at: point, on: page, for: item) { fillFrame(item, t); return true }
        return switch item {
        case .story(let id): addBlock(id, on: page, at: point) != nil
        case .photo(let a, let p): placePhoto(p, of: a, on: page, at: point) != nil
        case .quote(let a): placePullQuote(of: a, on: page, at: point) != nil
        case .extra(let id): placeExtra(id, on: page, at: point) != nil
        case .component(let id, let n): placeComponent(id, version: n, on: page, at: point) != nil
        }
    }

    /// An image or PDF file dropped straight onto a page: it comes in as a picture (a PDF as an ad) and runs there.
    func dropFile(_ url: URL, on page: Int, at point: CGPoint) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "pdf"].contains(ext),
              let id = addExtra(ext == "pdf" ? .ad : .image, file: url) else { return }
        placeExtra(id, on: page, at: point)
    }

    // MARK: pages

    /// Empty every page so the paper can be built by hand, dragging stories in from the inspector.
    func clearPages() {
        guard !isEditingTemplate else { return }
        edit("Clear Pages") {
            var l = issue.layout ?? IssueLayout()
            if l.pages.isEmpty { l.columns = HouseStyle.columns(averageCharWidth: HouseStyle.averageCharWidth(of: "")).columns }
            l.pages = (0..<max(l.pages.count, 4, issue.pagePlan.keptPageCount)).map { PageLayout(isFront: $0 == 0) }
            l.basis = issue.articles.map(\.id)
            issue.layout = l
            issue.placeTemplateComponents()                        // the template's: the Header on page 1, the Folio on the rest
        }
        canvasSelection = nil
        focusedPage = 0
    }

    func addPage(after i: Int? = nil) {
        guard let l = issue.layout else { return }
        let at = i.map { min($0 + 1, l.pages.count) } ?? l.pages.count
        edit("Add Page") { issue.layout!.pages.insert(PageLayout(), at: at); issue.placeRepeaters(onPage: at) }
        focusedPage = at
    }

    /// Take everything off one page.
    func clearPage(_ i: Int) {
        guard issue.layout?.pages.indices.contains(i) == true else { return }
        edit("Clear Page") {
            issue.layout!.pages[i].stories = []
            issue.layout!.pages[i].insets = []
        }
        canvasSelection = nil
    }

    /// Close the holes on a page: the story above each one runs down into it (or the one below reaches up).
    func fillHoles(on page: Int) {
        guard let holes = composedPages[safe: page]?.holes, !holes.isEmpty, let p = issue.layout?.pages[safe: page] else { return }
        edit("Fill Holes") {
            var stretched: [StoryBlock.ID] = []
            for h in holes {
                let across = p.stories.filter { $0.frame.rect.maxX > h.rect.minX + 1 && $0.frame.rect.minX < h.rect.maxX - 1 }
                if let above = across.filter({ $0.frame.rect.maxY <= h.rect.minY + 2 }).max(by: { $0.frame.rect.maxY < $1.frame.rect.maxY }) {
                    var r = above.frame.rect
                    r.size.height = h.rect.maxY - r.minY
                    setBlockFrame(above.id, page: page, frame: r)
                    stretched.append(above.id)
                } else if let below = across.filter({ $0.frame.rect.minY >= h.rect.maxY - 2 }).min(by: { $0.frame.rect.minY < $1.frame.rect.minY }) {
                    var r = below.frame.rect
                    r.size.height = r.maxY - h.rect.minY
                    r.origin.y = h.rect.minY
                    setBlockFrame(below.id, page: page, frame: r)
                    stretched.append(below.id)
                }
            }
            for id in stretched { absorb(into: id, on: page) }      // what the text can't fill, the story's art does
        }
    }

    /// Select a story's block on the canvas; clicking again walks through its parts.
    func jump(to story: Article.ID, blocks: [(page: Int, id: StoryBlock.ID)]) {
        guard !blocks.isEmpty else { return }
        var k = 0
        if let last = lastJump, last.story == story { k = (last.index + 1) % blocks.count }
        lastJump = (story, k)
        canvasSelection = .block(blocks[k].id)
        focusedPage = blocks[k].page
    }

    /// A block or picture dragged off the canvas into the inspector: the story goes on hold, the picture comes off the page.
    func dropOutside(_ what: LayoutSelection) {
        switch what {
        case .block(let id): if let (_, b) = block(id) { parkStory(b.article) }
        case .inset(let id): removeInset(id)
        case .component(let id): removeComponent(id)
        }
    }

    func removePage(_ i: Int) {
        guard let l = issue.layout, l.pages.indices.contains(i), !l.pages[i].isFront, l.pages.count > 1 else { return }
        edit("Remove Page") { issue.layout!.pages.remove(at: i) }
        canvasSelection = nil
        focusedPage = min(i, issue.layout!.pages.count - 1)
    }

    /// Take a story off every page; it waits in the inspector until it's dragged back.
    func parkStory(_ id: Article.ID) {
        edit("Dismiss Story") {
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].stories.removeAll { $0.article == id } }
        }
        canvasSelection = nil
    }

    // MARK: ads and graphics

    var selectedExtraIndex: Int? {
        guard let id = selection else { return nil }
        return issue.extras.firstIndex { $0.id == id }
    }

    /// Choose image or PDF files and add each as an ad, image or graphic.
    func addExtras(_ kind: Extra.Kind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the \(kind.rawValue.lowercased()) file"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addExtra(kind, file: url) }
    }

    @discardableResult
    func addExtra(_ kind: Extra.Kind, file url: URL) -> Extra.ID? {
        guard let path = importImage(url) else { return nil }
        var e = Extra(kind: kind, path: path, title: url.deletingPathExtension().lastPathComponent)
        if kind == .ad { e.columns = 2 }
        issue.extras.append(e)
        selection = e.id
        scheduleSave()
        return e.id
    }

    func removeExtra(_ id: Extra.ID) {
        let name = "Delete \(extra(id)?.kind.rawValue ?? "Item")"
        let before = (issue.extras, issue.layout)
        issue.extras.removeAll { $0.id == id }
        if issue.layout != nil {
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].insets.removeAll { $0.extra == id } }
            dropFills(extra: id)
        }
        // one undo step puts back the ad and everywhere it was placed
        registerExtrasUndo(before, name)
        if selection == id { selection = issue.articles.first?.id }
        scheduleSave()
    }

    private func registerExtrasUndo(_ before: ([Extra], IssueLayout?), _ name: String) {
        undoManager?.registerUndo(withTarget: self) { s in
            let now = (s.issue.extras, s.issue.layout)
            s.issue.extras = before.0
            s.issue.layout = before.1
            s.pruneSelection()
            s.registerExtrasUndo(now, name)
            s.scheduleSave()
        }
        undoManager?.setActionName(name)
    }

    /// Pages an ad or graphic is on.
    func extraPages() -> [Extra.ID: [Int]] {
        var out: [Extra.ID: [Int]] = [:]
        for (i, p) in (issue.layout?.pages ?? []).enumerated() {
            for inset in p.insets { if let e = inset.extra { out[e, default: []].append(i + 1) } }
        }
        return out
    }

    /// Where an ad or graphic goes at its intended width: at `point`, else the foot of the biggest free space.
    func extraFrame(_ e: Extra, on page: Int, at point: CGPoint?) -> CGRect? {
        guard issue.layout?.pages.indices.contains(page) == true else { return nil }
        let g = grid
        let span = e.columns.clamped(1, g.columns)
        let w = g.span(span)
        let h = e.height ?? w / composer.aspect(path: e.path)
        var r: CGRect
        if let point {
            r = CGRect(x: g.x(column(nearest: point.x, span: span)), y: point.y, width: w, height: h)
            r = snap(r, page: page, edges: [.top], move: false).rect
        } else if let free = freeSpace(on: page) {
            r = CGRect(x: free.maxX - w, y: free.maxY - h, width: w, height: h)      // ads sit at the foot, outside corner
        } else {
            r = CGRect(x: HouseStyle.margin + HouseStyle.liveWidth - w, y: HouseStyle.bottom - h, width: w, height: h)
        }
        return onPage(snap(r))
    }

    /// Put an ad or graphic on a page at its intended width. Text there wraps around it and the stories tighten.
    @discardableResult
    func placeExtra(_ id: Extra.ID, on page: Int, at point: CGPoint? = nil) -> Inset.ID? {
        guard let e = extra(id), let r = extraFrame(e, on: page, at: point) else { return nil }
        let inset = Inset(kind: .extra, article: nil, photo: nil, extra: id, frame: Box(r))
        edit("Place \(e.kind.rawValue)") { issue.layout!.pages[page].insets.append(inset) }
        canvasSelection = .inset(inset.id)
        focusedPage = page
        return inset.id
    }

    // MARK: story blocks

    func block(_ id: StoryBlock.ID) -> (page: Int, block: StoryBlock)? {
        guard let layout = issue.layout else { return nil }
        for (i, p) in layout.pages.enumerated() {
            if let b = p.stories.first(where: { $0.id == id }) { return (i, b) }
        }
        return nil
    }

    func article(_ id: Article.ID?) -> Article? { id.flatMap { id in issue.articles.first { $0.id == id } } }
    func extra(_ id: Extra.ID?) -> Extra? { id.flatMap { id in issue.extras.first { $0.id == id } } }

    /// How each placed story is copyfit, from the current composition.
    var fits: [Article.ID: FitInfo] { _ = displayPages; return composer.fits }

    /// Square inches a story would take at the house style, for one not yet on a page.
    func estimatedArea(_ a: Article) -> Double {
        Double(composer.lineCount(a, start: 0, continuedFrom: nil, width: grid.colWidth)) * Double(HouseStyle.leading) * Double(grid.colWidth) / 5184
    }

    /// Pictures that belong with a block: the story's own, lying inside its frame.
    func insets(with block: StoryBlock, on page: Int) -> [Inset] {
        issue.layout?.pages[safe: page]?.insets.filter {
            $0.article == block.article && block.frame.rect.insetBy(dx: -1, dy: -1).intersects($0.frame.rect)
        } ?? []
    }

    /// Move or resize a block. It comes to the front: stories under it wrap around it.
    func setBlockFrame(_ id: StoryBlock.ID, page: Int, frame: CGRect) {
        guard let k = issue.layout?.pages[safe: page]?.stories.firstIndex(where: { $0.id == id }) else { return }
        var b = issue.layout!.pages[page].stories.remove(at: k)
        let r = CGRect(x: frame.minX, y: frame.minY, width: max(grid.colWidth, frame.width), height: max(40, frame.height))
        b.frame = Box(r)
        let n = columns(for: r.width)
        if n != b.columns, b.headlineSize == HouseStyle.headlineSize(columns: b.columns) {
            b.headlineSize = HouseStyle.headlineSize(columns: n)       // house size follows the width unless it was set by hand
        }
        b.columns = n
        b.bylineColumns = min(b.bylineColumns, n)
        issue.layout!.pages[page].stories.append(b)
        if !editing { scheduleSave() }
    }

    /// Carry a block (and the pictures inside it) to another page.
    func moveBlock(_ id: StoryBlock.ID, from: Int, to: Int, frame: CGRect) {
        guard var layout = issue.layout, layout.pages.indices.contains(to),
              let k = layout.pages[from].stories.firstIndex(where: { $0.id == id }) else { return }
        let old = layout.pages[from].stories[k]
        let dx = frame.minX - old.frame.x, dy = frame.minY - old.frame.y
        var b = layout.pages[from].stories.remove(at: k)
        b.frame = Box(frame)
        layout.pages[to].stories.append(b)
        for inset in insets(with: old, on: from) {
            layout.pages[from].insets.removeAll { $0.id == inset.id }
            var i = inset
            i.frame = Box(inset.frame.rect.offsetBy(dx: dx, dy: dy))
            layout.pages[to].insets.append(i)
        }
        issue.layout = layout
        focusedPage = to
        if !editing { scheduleSave() }
    }

    func removeBlock(_ id: StoryBlock.ID) {
        edit("Remove Story Block") {
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].stories.removeAll { $0.id == id } }
        }
        if selectedBlock == id { canvasSelection = nil }
    }

    /// When a story's display type changes height (a kicker added, a headline that now takes another line, a
    /// byline that wraps), the pictures placed in its blocks move with the body: what sat under the headline
    /// stays under it, and what sat on a line of the body stays on that line. So the paper keeps up with edits
    /// without being generated again.
    func reflowArt(for old: Article, now new: Article) {
        guard old.id == new.id, let layout = issue.layout,
              old.headline != new.headline || old.kicker != new.kicker || old.author != new.author || old.authorTitle != new.authorTitle else { return }
        var moved = layout
        var any = false
        for (p, page) in layout.pages.enumerated() {
            for b in page.stories where b.article == new.id {
                let f = b.frame.rect
                let before = composer.blockGeometry(old, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: [], bylineColumns: b.bylineColumns, draw: false)
                let after = composer.blockGeometry(new, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: [], bylineColumns: b.bylineColumns, draw: false)
                let delta = after.bodyTop - before.bodyTop
                guard abs(delta) > 0.5 else { continue }
                for k in moved.pages[p].insets.indices {
                    let inset = moved.pages[p].insets[k]
                    let r = inset.frame.rect
                    // the story's own art inside this block, at or below where the body used to start
                    guard inset.article == new.id, r.intersects(f), r.minY >= before.bodyTop - 4 else { continue }
                    var moved_r = r.offsetBy(dx: 0, dy: delta)
                    if moved_r.maxY > HouseStyle.bottom { moved_r.origin.y = max(after.bodyTop, HouseStyle.bottom - r.height) }
                    moved.pages[p].insets[k].frame = Box(moved_r)
                    any = true
                }
            }
        }
        if any { issue.layout = moved }
    }

    /// How many of its columns a block's byline spans: wider for a long shared byline.
    func setBylineColumns(_ n: Int, block id: StoryBlock.ID) {
        guard let (page, b) = block(id) else { return }
        let want = n.clamped(1, b.columns)
        guard want != b.bylineColumns, let k = issue.layout?.pages[page].stories.firstIndex(where: { $0.id == id }) else { return }
        edit("Byline Width") { issue.layout!.pages[page].stories[k].bylineColumns = want }
    }

    func setColumns(_ n: Int, block id: StoryBlock.ID) {
        guard let (page, b) = block(id) else { return }
        var r = b.frame.rect
        r.size.width = grid.span(n.clamped(1, grid.columns))
        r.origin.x = min(r.origin.x, HouseStyle.margin + HouseStyle.liveWidth - r.width)
        edit("Change Columns") { setBlockFrame(id, page: page, frame: grid.snap(r)) }
    }

    func setHeadlineSize(_ size: CGFloat, block id: StoryBlock.ID) {
        edit("Headline Size") { setHeadline(size, block: id) }
    }

    private func setHeadline(_ size: CGFloat, block id: StoryBlock.ID) {
        guard let (page, _) = block(id), let k = issue.layout?.pages[page].stories.firstIndex(where: { $0.id == id }) else { return }
        issue.layout!.pages[page].stories[k].headlineSize = size.clamped(14, 60)
    }

    /// Shrink or grow the block to the shortest height that holds its text.
    func fitBlock(_ id: StoryBlock.ID) {
        guard let (page, b) = block(id), let a = article(b.article) else { return }
        edit("Fit Height to Text") { setBlockFrame(id, page: page, frame: fitted(b, on: page, article: a)) }
    }

    /// The block's height at which it would hold its text exactly at house style (set `fit` for tighter or looser):
    /// as tight as is comfortable, at house style, and as loose as is comfortable.
    /// The band shown while an edge is pulled. It reads the paper as it's on screen, so grabbing an edge never
    /// waits for fits still being worked out in the background; it only needs where the story starts in the block.
    func fitHeights(_ b: StoryBlock, on page: Int, article a: Article) -> (tight: CGFloat, house: CGFloat, loose: CGFloat) {
        let shown = displayPages
        return (fitted(b, on: page, article: a, fit: Fit(level: -Fit.comfortable), pages: shown).height,
                fitted(b, on: page, article: a, pages: shown).height,
                fitted(b, on: page, article: a, fit: Fit(level: Fit.comfortable), pages: shown).height)
    }

    func fitted(_ b: StoryBlock, on page: Int, article a: Article, fit: Fit = .neutral, pages: [ComposedPage]? = nil) -> CGRect {
        let composed = pages ?? composedPages
        let result = composed[safe: page]?.blockResults[b.id]
        let start = result?.start ?? composed[safe: page]?.incoming[b.article] ?? 0
        let r = b.frame.rect
        let need = composer.lineCount(a, start: start, continuedFrom: result?.continuedFrom, width: grid.colWidth, fit: fit)
        let avoid = (issue.layout?.pages[safe: page]?.insets ?? []).compactMap { i in
            composer.geometry(i, article(i.article), extra(i.extra)).map { Composer.wrap($0.full) }
        }
        let aligned = issue.layout?.pages[safe: page].flatMap { p in
            composer.alignedBodyTops(p, articles: Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                     composer.obstacles(p, articles: Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })))[b.id]
        }
        func room(_ h: CGFloat) -> Int {
            let g = composer.blockGeometry(a, frame: CGRect(x: r.minX, y: r.minY, width: r.width, height: h), columns: b.columns,
                                           headlineSize: b.headlineSize, avoid: avoid, bylineColumns: b.bylineColumns, bodyTop: aligned, draw: false)
            return composer.capacity(g, jump: false, leading: fit.leading).reduce(0, +)      // sized to hold it all: no jump line
        }
        let maxH = HouseStyle.bottom - r.minY
        guard need > 0 else { return CGRect(x: r.minX, y: r.minY, width: r.width, height: 60) }
        guard room(maxH) >= need else { return CGRect(x: r.minX, y: r.minY, width: r.width, height: maxH) }
        var lo: CGFloat = 40, hi = maxH
        while hi - lo > 1 {
            let mid = ((lo + hi) / 2).rounded()
            if room(mid) >= need { hi = mid } else { lo = mid }
        }
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: hi)
    }

    /// Stretch the block down to whatever is below it, or the bottom margin.
    func fillDown(_ id: StoryBlock.ID) {
        guard let (page, b) = block(id) else { return }
        edit("Fill Down") {
            var r = b.frame.rect
            r.size.height = floor(below: r, on: page, excluding: [id]) - r.minY
            setBlockFrame(id, page: page, frame: r)
        }
    }

    /// Fill Down, then take up what the text can't fill the way the generator does: the story's lead photo sized
    /// to the gap, its pull quote, a bigger headline, a taller photo. Whatever is still blank stays flagged.
    func fillSpace(_ id: StoryBlock.ID) {
        guard let (page, b) = block(id) else { return }
        edit("Fill Space") {
            var r = b.frame.rect
            r.size.height = floor(below: r, on: page, excluding: [id]) - r.minY
            setBlockFrame(id, page: page, frame: r)
            absorb(into: id, on: page)
        }
        canvasSelection = .block(id)
    }

    /// Lines a block can't fill at this moment, set as loose as allowed.
    private func blankLines(in id: StoryBlock.ID, on page: Int) -> Int {
        composedPages[safe: page]?.blockResults[id]?.empty ?? 0
    }

    /// The composing editor's tricks, in order, until the block fills or they run out. Caller holds the edit.
    private func absorb(into id: StoryBlock.ID, on page: Int) {
        guard let b0 = block(id)?.block, let a = article(b0.article) else { return }
        func current() -> StoryBlock? { issue.layout?.pages[safe: page]?.stories.first { $0.id == id } }
        let tolerance = 2
        func bodyTop(_ b: StoryBlock) -> CGFloat {
            let hh = composer.headlineHeight(a, width: b.frame.w, size: b.headlineSize)
            return b.frame.y + hh + (hh > 0 ? 7 : 0)
        }
        var placed: Inset.ID?
        // 1. the story's lead photo, in the house spot, as tall as the gap asks for (within the house limits)
        if blankLines(in: id, on: page) > tolerance, let b = current(),
           let p = a.photos.first(where: { artPlacements().photos[$0.id] == nil }) {
            let g = grid
            let span = max(1, b.columns - 1), w = g.span(span)
            let cap = Composer.caption(p, width: w).map { composer.height(of: $0, width: w) + 4 } ?? 0
            let top = bodyTop(b)
            let want = CGFloat(blankLines(in: id, on: page)) * HouseStyle.leading / CGFloat(span) - cap - 18
            // never taller than the picture really is, nor than the house allows (0.85 of its width)
            let maxH = max(60, min(0.85 * w, w / composer.aspect(p), (b.frame.rect.maxY - top) * 0.6))
            let h = want.clamped(min(0.42 * w, maxH), maxH)
            placed = insertPhoto(p.id, of: a.id, on: page, frame: CGRect(x: b.frame.rect.maxX - w, y: top + 4, width: w, height: h))
        }
        // 2. its pull quote, in a middle column
        if blankLines(in: id, on: page) > tolerance, !a.pullQuote.trimmed.isEmpty, artPlacements().quotes[a.id] == nil,
           let f = quoteFrame(of: a, on: page, at: nil, in: id) {
            insertQuote(of: a.id, on: page, frame: f)
        }
        // 3. a bigger headline, a step at a time; the photo under it moves down to stay clear
        while blankLines(in: id, on: page) > tolerance, let b = current(), b.headlineSize < 48 {
            setHeadline(b.headlineSize + 6, block: id)
            if let placed, let b = current(), let k = issue.layout?.pages[page].insets.firstIndex(where: { $0.id == placed }) {
                var f = issue.layout!.pages[page].insets[k].frame.rect
                f.origin.y = bodyTop(b) + 4
                issue.layout!.pages[page].insets[k].frame = Box(f)
            }
        }
        // 4. a cropped photo in the block gets its height back, up to what it really is and the house limit
        if blankLines(in: id, on: page) > tolerance, let b = current(),
           let photo = insets(with: b, on: page).first(where: { $0.kind == .photo }),
           let p = a.photos.first(where: { $0.id == photo.photo }) {
            var f = photo.frame.rect
            let span = max(1, columns(for: f.width))
            let cap = min(0.85 * f.width, f.width / composer.aspect(p))
            let h = min(cap, f.height + CGFloat(blankLines(in: id, on: page)) * HouseStyle.leading / CGFloat(span))
            if h > f.height + 2 { f.size.height = h; setInsetFrame(photo.id, page: page, frame: f) }
        }
    }

    /// The nearest edge below a frame among the page's other items, else the bottom margin.
    private func floor(below r: CGRect, on page: Int, excluding: Set<UUID>) -> CGFloat {
        var y = HouseStyle.bottom
        guard let p = issue.layout?.pages[safe: page] else { return y }
        let frames = p.stories.filter { !excluding.contains($0.id) }.map(\.frame.rect)
            + p.insets.filter { !excluding.contains($0.id) }.map(\.frame.rect)
        for f in frames where f.minY >= r.minY + 20 && f.maxX > r.minX && f.minX < r.maxX {
            y = min(y, f.minY - HouseStyle.moduleGap)
        }
        return y
    }

    /// The biggest empty area on a page, as a frame on the column grid.
    func freeSpace(on page: Int) -> CGRect? {
        guard let p = issue.layout?.pages[safe: page] else { return nil }
        let top = p.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        let frames = p.stories.map(\.frame.rect) + p.insets.map(\.frame.rect)
        let g = grid
        var best: (area: CGFloat, rect: CGRect)?
        for c0 in 0..<g.columns {
            for c1 in c0..<g.columns {
                let x0 = g.x(c0), x1 = g.x(c1) + g.colWidth
                var y = top
                for f in frames where f.maxX > x0 && f.minX < x1 { y = max(y, f.maxY + HouseStyle.moduleGap) }
                let h = HouseStyle.bottom - y
                guard h >= 120 else { continue }
                let r = CGRect(x: x0, y: y, width: x1 - x0, height: h)
                if best == nil || r.width * r.height > best!.area { best = (r.width * r.height, r) }
            }
        }
        return best?.rect
    }

    /// Where a story's block starts out on a page: at `point` (two columns, running down to whatever is below), else
    /// the biggest empty space, else two columns at the foot for the editor to make room. Not yet sized to its text.
    private func startingFrame(for a: Article, on page: Int, at point: CGPoint?) -> CGRect? {
        guard let pl = issue.layout?.pages[safe: page] else { return nil }
        let g = grid
        let top = pl.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        if let point {
            let span = min(2, g.columns)
            let c = column(nearest: point.x, span: span)
            let y = point.y.clamped(top, HouseStyle.bottom - 120)
            var frame = CGRect(x: g.x(c), y: y, width: g.span(span), height: 120)
            frame.origin.y = snap(frame, page: page, edges: [.top], move: false).rect.minY
            frame.size.height = max(120, floor(below: frame, on: page, excluding: []) - frame.minY)
            return frame
        }
        if let free = freeSpace(on: page) { return free }
        return CGRect(x: g.x(0), y: HouseStyle.bottom - 260, width: g.span(min(2, g.columns)), height: 260)
    }

    /// Where a story dropped at `point` would sit, sized to its text.
    func blockFrame(for a: Article, on page: Int, at point: CGPoint?) -> CGRect? {
        guard let frame = startingFrame(for: a, on: page, at: point) else { return nil }
        let n = columns(for: frame.width)
        let b = StoryBlock(article: a.id, frame: Box(frame), columns: n, headlineSize: HouseStyle.headlineSize(columns: n))
        // asked on every pointer move of a drag from the inspector: read the paper as shown, never wait on fits
        return fitted(b, on: page, article: a, pages: displayPages)
    }

    /// Put a story on a page: at `point` if given, else in the biggest empty space. The block is sized to its text.
    @discardableResult
    func addBlock(_ article: Article.ID, on page: Int, at point: CGPoint? = nil) -> StoryBlock.ID? {
        guard let a = self.article(article), let frame = startingFrame(for: a, on: page, at: point) else { return nil }
        let n = columns(for: frame.width)
        var b = StoryBlock(article: article, frame: Box(frame), columns: n, headlineSize: HouseStyle.headlineSize(columns: n))
        edit("Add Story") {
            issue.layout!.pages[page].stories.append(b)
            let fit = fitted(b, on: page, article: a)
            b.frame = Box(fit)
            issue.layout!.pages[page].stories[issue.layout!.pages[page].stories.count - 1] = b
        }
        canvasSelection = .block(b.id)
        focusedPage = page
        return b.id
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        if selectionSet.count > 1 { nudgeSet(dx: dx, dy: dy); return }        // several items: Store+MultiSelect.swift
        switch canvasSelection {
        case .block(let id):
            guard let (page, b) = block(id) else { return }
            // the block stops at the page edge; its pictures move by what the block actually moved
            let moved = onPage(b.frame.rect.offsetBy(dx: dx, dy: dy))
            let (mx, my) = (moved.minX - b.frame.x, moved.minY - b.frame.y)
            guard mx != 0 || my != 0 else { return }
            edit("Move") {
                for i in insets(with: b, on: page) { setInsetFrame(i.id, page: page, frame: i.frame.rect.offsetBy(dx: mx, dy: my)) }
                setBlockFrame(id, page: page, frame: moved)
            }
        case .inset(let id):
            guard let layout = issue.layout, let page = layout.pages.firstIndex(where: { $0.insets.contains { $0.id == id } }),
                  let i = layout.pages[page].insets.first(where: { $0.id == id }) else { return }
            edit("Move") { setInsetFrame(id, page: page, frame: onPage(i.frame.rect.offsetBy(dx: dx, dy: dy))) }
        case .component(let id):
            guard let (page, c) = placedComponent(id) else { return }
            edit("Move") { setComponentFrame(id, page: page, frame: onPage(c.frame.rect.offsetBy(dx: dx, dy: dy))) }
        case nil: break
        }
    }

    func deleteSelection() {
        if selectionSet.count > 1 { deleteSet(); return }
        switch canvasSelection {
        case .block(let id): removeBlock(id)
        case .inset(let id): removeInset(id)
        case .component(let id): removeComponent(id)
        case nil: break
        }
    }

    // MARK: story status

    struct StoryStatus {
        var pages: [Int] = []            // page numbers, in reading order
        var overset = 0                  // lines with nowhere to go
        var complete = false
        var empty = 0                    // empty body lines across its blocks
        var blocks: [(page: Int, id: StoryBlock.ID)] = []
        var firstBlock: (page: Int, id: StoryBlock.ID)? { blocks.first }
    }

    func storyStatus() -> [Article.ID: StoryStatus] {
        var out: [Article.ID: StoryStatus] = [:]
        guard let layout = issue.layout else { return out }
        let composed = displayPages
        for (i, p) in layout.pages.enumerated() {
            // a story set in a component's body or whole-story frame runs there too (phase 5): it isn't on hold
            let inFrames = componentBlocks(on: i)
            for b in PageLayout.readingOrder(p.stories + inFrames.map(\.block)) {
                var st = out[b.article] ?? StoryStatus()
                if st.pages.last != i + 1 { st.pages.append(i + 1) }
                let framed = inFrames.first { $0.block.id == b.id }
                if framed == nil { st.blocks.append((i, b.id)) }
                if let r = framed.map({ composed[safe: i]?.componentBlockResults[$0.placed]?[$0.frame] }) ?? composed[safe: i]?.blockResults[b.id] {
                    st.overset = r.oversetLines
                    st.complete = r.end >= r.total
                    st.empty += r.empty
                }
                out[b.article] = st
            }
        }
        return out
    }

    func exportPDF() {
        guard issue.layout != nil, confirmExportWithEmptyFrames("PDF") else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "polytechnic-\(f.string(from: issue.date)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if PDFExport.write(composedPages, to: url) { NSWorkspace.shared.open(url) }
    }

    /// The paper as an IDML package InDesign opens directly, pictures embedded, so one file carries the issue.
    func exportIDML() {
        guard issue.layout != nil, confirmExportWithEmptyFrames("InDesign file") else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "idml") ?? .data]
        panel.title = "Export for InDesign"
        panel.message = "An IDML package InDesign opens as this paper, with its pictures inside."
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "polytechnic-\(f.string(from: issue.date)).idml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let written = try IDMLExport.write(issue, pages: composedPages, composer: composer, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([written])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't write the InDesign file"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    func exportIssue() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "issue-\(f.string(from: issue.date)).json"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Self.encoder().encode(issue) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
