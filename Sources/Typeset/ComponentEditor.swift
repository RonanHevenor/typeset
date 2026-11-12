import AppKit
import Observation

// The component editor (phase 6): one component on a canvas at its own size, sitting on a faded page so its
// edges can snap to the page's margins and columns. It edits a draft of one version; Save makes the draft a new
// version, and opening an old version from the history makes it the base of the next. The pointer goes through
// the same hit test as the pages (`CanvasHitTest`), and a state machine with the pages' rules
// (`ComponentEditor+Pointer.swift`). The window is in `ComponentEditorView.swift`, the files in
// `ComponentFiles.swift`.

/// What can be selected in the editor: the component itself (its edges resize it, the inspector shows its name,
/// columns and gutter) or one of its elements.
enum EditorSelection: Hashable {
    case component
    case element(UUID)

    var elementID: UUID? { if case .element(let id) = self { id } else { nil } }
}

/// The tool the next press on the canvas uses. Select picks things up; the others draw a new element (a drag
/// sets its size, a click puts down one of a standard size) and hand back to Select.
enum EditorTool: String, CaseIterable, Identifiable {
    case select, frame, line, rect, ellipse, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "Select"; case .frame: "Frame"; case .line: "Line"; case .rect: "Rectangle"
        case .ellipse: "Ellipse"; case .text: "Text"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .frame: "rectangle.dashed"; case .line: "line.diagonal"
        case .rect: "rectangle"; case .ellipse: "circle"; case .text: "textformat"
        }
    }
}

// MARK: - element geometry

extension Element {
    /// The element's box in the component's points. A line's is the box its two ends span (no height for a level
    /// rule); setting it moves and stretches the line's ends with the box.
    var box: Box {
        get {
            switch self {
            case .frame(let f): return f.box
            case .rect(let s), .ellipse(let s): return s.box
            case .text(let t): return t.box
            case .art(let a): return a.box
            case .line(let l):
                return Box(x: min(l.x1, l.x2), y: min(l.y1, l.y2), w: abs(l.x2 - l.x1), h: abs(l.y2 - l.y1))
            }
        }
        set {
            switch self {
            case .frame(var f): f.box = newValue; self = .frame(f)
            case .rect(var s): s.box = newValue; self = .rect(s)
            case .ellipse(var s): s.box = newValue; self = .ellipse(s)
            case .text(var t): t.box = newValue; self = .text(t)
            case .art(var a): a.box = newValue; self = .art(a)
            case .line(var l):
                let old = box
                // each end keeps its place in the box; a line with no extent on an axis (upright or level) gets
                // one from its second end, so a width or height typed in, or pulled out by a handle, takes
                func map(_ v: CGFloat, second: Bool, _ o: CGFloat, _ ow: CGFloat, _ n: CGFloat, _ nw: CGFloat) -> CGFloat {
                    ow > 0 ? n + (v - o) / ow * nw : (second ? n + nw : n)
                }
                l.x1 = map(l.x1, second: false, old.x, old.w, newValue.x, newValue.w); l.x2 = map(l.x2, second: true, old.x, old.w, newValue.x, newValue.w)
                l.y1 = map(l.y1, second: false, old.y, old.h, newValue.y, newValue.h); l.y2 = map(l.y2, second: true, old.y, old.h, newValue.y, newValue.h)
                self = .line(l)
            }
        }
    }

    var kindTitle: String {
        switch self {
        case .frame(let f): "\(f.type.title) frame" + (f.link.map { " \($0)" } ?? "")
        case .line: "Line"; case .rect: "Rectangle"; case .ellipse: "Ellipse"; case .text: "Text"
        case .art(let a): a.name.isEmpty ? "Art" : a.name
        }
    }

    /// The same element under a new id (Duplicate).
    func copied() -> Element {
        switch self {
        case .frame(var f): f.id = UUID(); return .frame(f)
        case .line(var l): l.id = UUID(); return .line(l)
        case .rect(var s): s.id = UUID(); return .rect(s)
        case .ellipse(var s): s.id = UUID(); return .ellipse(s)
        case .text(var t): t.id = UUID(); return .text(t)
        case .art(var a): a.id = UUID(); return .art(a)
        }
    }
}

extension ComponentVersion {
    /// What a version draws and how it's sized, without its number and date: whether two versions look the same.
    func sameContent(as o: ComponentVersion) -> Bool {
        width == o.width && height == o.height && columns == o.columns && gutter == o.gutter && elements == o.elements
    }
}

// MARK: - the editor

@Observable
final class ComponentEditor {
    /// The component as saved: its name and every version (the history).
    private(set) var component: Component
    /// What's being edited: the draft of the next version.
    var draft: ComponentVersion
    /// The name the draft will be saved under.
    var name: String
    /// The version the draft started from (nil for a component never saved).
    private(set) var base: Int?
    /// The .typesetcomponent file this component is saved in; nil until it has one.
    var fileURL: URL?

    /// Where the component sits on the editor's page, in page points. Only for snapping its edges to the page's
    /// margins and columns; it isn't saved.
    var origin: CGPoint
    /// The page's column count, which the component's columns default to (decision 8).
    var pageColumns: Int
    /// The issue's facts, for what the issue-field frames show (page 1 of this issue).
    @ObservationIgnored var facts = Issue()

    var selection: EditorSelection?
    var tool: EditorTool = .select
    /// What the Frame tool makes.
    var frameType: FrameType = .headline
    var frameLink: String?
    /// The fill colour: new rectangles and ellipses take it, and the colour well applies it to the selection.
    var fillColor = Paint.red
    /// The line weight, in points: new lines take it, and it's put on the selection (a line, or a shape's stroke).
    var lineWeight: CGFloat = 0.5
    static let lineWeights: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]
    var zoom: CGFloat = 1

    // the pointer (ComponentEditor+Pointer.swift)
    var pointer = EditorPointerState()
    var hovered: EditorSelection?
    var hoverEdge: ResizeZone?
    var guides: [Guide] = []
    @ObservationIgnored var hover: CGPoint?
    @ObservationIgnored var snapOff = false

    @ObservationIgnored var undoManager: UndoManager? = UndoManager()
    @ObservationIgnored private var editing = false
    @ObservationIgnored private var editBefore: Snapshot?
    @ObservationIgnored let composer = Composer()
    @ObservationIgnored private let pageID = UUID()
    @ObservationIgnored private let placedID = UUID()
    /// Which page of the issue the component is drawn on: 0 in the editor's window; in place (phase 7) the page
    /// it's placed on, so its issue fields read as they do there. Empty pages ahead of it, kept for the composer's cache.
    @ObservationIgnored var pageIndex = 0
    /// In place (phase 7): the drawing tools draw inside the component only; the faded page round it takes no press.
    @ObservationIgnored var drawsInsideOnly = false
    @ObservationIgnored private var leadingPages: [UUID] = []
    /// The version Edit… asked for (nil: the newest), so a second Edit… on an open component can show it.
    @ObservationIgnored private(set) var requestedVersion: Int?

    static let pad: CGFloat = 48           // the canvas round the page, in screen points

    init(component: Component, version: Int? = nil, fileURL: URL? = nil, origin: CGPoint? = nil, pageColumns: Int = 3) {
        var c = component
        c.versions.sort { $0.number < $1.number }
        self.component = c
        self.fileURL = fileURL
        self.pageColumns = max(1, pageColumns)
        let v = version.flatMap { c.version($0) } ?? c.latest
        draft = v ?? ComponentVersion(number: 1, width: HouseStyle.liveWidth, height: 200)
        base = v?.number
        requestedVersion = version.flatMap { c.version($0) }?.number
        name = c.name
        self.origin = origin ?? CGPoint(x: HouseStyle.margin, y: HouseStyle.insideTop)
        // a component wider or taller than the page sits at the page's corner
        if self.origin.x + draft.width > HouseStyle.page.width { self.origin.x = max(0, HouseStyle.page.width - draft.width) }
        if self.origin.y + draft.height > HouseStyle.page.height { self.origin.y = max(0, HouseStyle.page.height - draft.height) }
        undoManager?.levelsOfUndo = 200
    }

    /// A new, empty component: the live width of the page, 200 points high, with the page's columns.
    static func newComponent(pageColumns: Int = 3) -> ComponentEditor {
        let e = ComponentEditor(component: Component(name: "Untitled Component"), pageColumns: pageColumns)
        e.draft = ComponentVersion(number: 1, width: HouseStyle.liveWidth, height: 200)
        return e
    }

    // MARK: what it is

    var id: Component.ID { component.id }
    var versions: [ComponentVersion] { component.versions }
    var columns: Int { max(1, draft.columns ?? pageColumns) }
    var gutter: CGFloat { ComponentVersion.clampedGutter(draft.gutter ?? HouseStyle.gutter, width: draft.width, columns: columns) }
    /// The component on the page.
    var rect: CGRect { CGRect(origin: origin, size: draft.size) }

    /// Unsaved: a component never saved, or a draft (or name) that differs from the version it started from.
    var isEdited: Bool {
        guard let b = base.flatMap({ component.version($0) }) else { return true }
        return !draft.sameContent(as: b) || name != component.name
    }

    var title: String { "\(name) – " + (base.map { isEdited ? "edited from v\($0)" : "v\($0)" } ?? "new") }

    /// The component's own columns, on the page.
    var columnRects: [CGRect] {
        let n = columns, g = gutter
        let w = (draft.width - CGFloat(n - 1) * g) / CGFloat(n)
        return (0..<n).map { CGRect(x: origin.x + CGFloat($0) * (w + g), y: origin.y, width: max(0, w), height: draft.height) }
    }

    func element(_ id: UUID?) -> Element? { id.flatMap { id in draft.elements.first { $0.id == id } } }
    var selectedElement: Element? { element(selection?.elementID) }

    /// An element's box on the page.
    func pageRect(_ e: Element) -> CGRect { e.box.rect.offsetBy(dx: origin.x, dy: origin.y) }
    func pageRect(of sel: EditorSelection) -> CGRect? {
        switch sel {
        case .component: rect
        case .element(let id): element(id).map(pageRect)
        }
    }

    // MARK: undo

    struct Snapshot: Equatable {
        var draft: ComponentVersion
        var name: String
        var origin: CGPoint
        var base: Int?
    }
    private var snapshot: Snapshot { Snapshot(draft: draft, name: name, origin: origin, base: base) }
    private func restore(_ s: Snapshot) {
        draft = s.draft; name = s.name; origin = s.origin; base = s.base
        if let id = selection?.elementID, element(id) == nil { selection = nil }
    }

    private func registerUndo(_ before: Snapshot, _ actionName: String) {
        undoManager?.registerUndo(withTarget: self) { e in
            let now = e.snapshot
            e.restore(before)
            e.registerUndo(now, actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// One change, one undo step.
    func edit(_ actionName: String, _ change: () -> Void) {
        let before = snapshot
        change()
        guard before != snapshot else { return }
        registerUndo(before, actionName)
    }

    /// A gesture: one undo step for the whole of it, opened only once the pointer has really moved.
    func beginEdit() {
        guard !editing else { return }
        editing = true
        editBefore = snapshot
    }
    var editingNow: Bool { editing }

    func endEdit(_ actionName: String) {
        guides = []
        guard editing else { return }
        editing = false
        guard let before = editBefore, before != snapshot else { return }
        if let um = undoManager, !um.isUndoing, !um.isRedoing {
            if um.groupsByEvent, um.groupingLevel == 1 { um.endUndoGrouping() }
            um.beginUndoGrouping()
            registerUndo(before, actionName)
            um.endUndoGrouping()
        } else {
            registerUndo(before, actionName)
        }
    }

    // MARK: elements

    /// Change one element in place (no undo step of its own; callers wrap it).
    func setElement(_ id: UUID, _ change: (inout Element) -> Void) {
        guard let i = draft.elements.firstIndex(where: { $0.id == id }) else { return }
        var e = draft.elements[i]
        change(&e)
        if e != draft.elements[i] { draft.elements[i] = e }
    }

    func update(_ id: UUID, _ actionName: String, _ change: (inout Element) -> Void) {
        edit(actionName) { setElement(id, change) }
    }

    /// Puts an element's box at `r` on the page.
    func setPageRect(_ id: UUID, _ r: CGRect) {
        setElement(id) { $0.box = Box(r.offsetBy(dx: -origin.x, dy: -origin.y)) }
    }

    @discardableResult
    func add(_ e: Element, _ actionName: String = "Add") -> UUID {
        edit(actionName) { draft.elements.append(e) }
        selection = .element(e.id)
        return e.id
    }

    func delete(_ id: UUID) {
        edit("Delete \(element(id)?.kindTitle ?? "Element")") { draft.elements.removeAll { $0.id == id } }
        if selection == .element(id) { selection = nil }
    }

    func deleteSelection() { if let id = selection?.elementID { delete(id) } }

    func duplicate(_ id: UUID) {
        guard let e = element(id) else { return }
        var c = e.copied()
        c.box = Box(e.box.rect.offsetBy(dx: 10, dy: 10))
        add(c, "Duplicate")
    }

    func bringToFront(_ id: UUID) {
        edit("Bring to Front") {
            guard let i = draft.elements.firstIndex(where: { $0.id == id }) else { return }
            draft.elements.append(draft.elements.remove(at: i))
        }
    }

    func sendToBack(_ id: UUID) {
        edit("Send to Back") {
            guard let i = draft.elements.firstIndex(where: { $0.id == id }) else { return }
            draft.elements.insert(draft.elements.remove(at: i), at: 0)
        }
    }

    /// Arrow keys: the selected element moves a point (ten with ⇧), as on the pages.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let id = selection?.elementID, let e = element(id) else { return }
        update(id, "Nudge") { $0.box = Box(e.box.rect.offsetBy(dx: dx, dy: dy)) }
    }

    /// The fill colour, put on the selection: a shape's fill, a line's colour, preset text's or a frame's type colour.
    func applyFill(_ p: Paint) {
        fillColor = p
        guard let id = selection?.elementID else { return }
        update(id, "Fill Colour") { e in
            switch e {
            case .rect(var s): s.fill = p; e = .rect(s)
            case .ellipse(var s): s.fill = p; e = .ellipse(s)
            case .line(var l): l.color = p; e = .line(l)
            case .text(var t): t.color = p; e = .text(t)
            case .frame(var f): f.color = p; e = .frame(f)
            case .art: break
            }
        }
    }

    /// The line weight, put on the selection: a line's width, or a shape's stroke (stroked in ink if it had none).
    func applyLineWeight(_ w: CGFloat) {
        let w = max(0.1, w)
        lineWeight = w
        guard let id = selection?.elementID else { return }
        update(id, "Line Weight") { e in
            switch e {
            case .line(var l): l.width = w; e = .line(l)
            case .rect(var s): s.strokeWidth = w; if s.stroke == nil { s.stroke = .ink }; e = .rect(s)
            case .ellipse(var s): s.strokeWidth = w; if s.stroke == nil { s.stroke = .ink }; e = .ellipse(s)
            case .text, .frame, .art: break
            }
        }
    }

    /// A new element of the tool's kind with its box at `r` (page points).
    func makeElement(_ tool: EditorTool, in r: CGRect) -> Element? {
        let b = Box(r.offsetBy(dx: -origin.x, dy: -origin.y))
        switch tool {
        case .select: return nil
        case .frame: return .frame(Frame(type: frameType, box: b, link: frameType.isIssueField || frameType == .ad ? nil : frameLink,
                                         dateFormat: frameType == .date ? Frame.defaultDateFormat : nil))
        case .line: return .line(LineElement(from: CGPoint(x: b.x, y: b.y), to: CGPoint(x: b.x + b.w, y: b.y + b.h), width: lineWeight))
        case .rect: return .rect(ShapeElement(box: b, fill: fillColor))
        case .ellipse: return .ellipse(ShapeElement(box: b, fill: fillColor))
        case .text: return .text(TextElement(box: b, text: "Text"))
        }
    }

    /// The box a click with a tool puts down, its top-left corner at `p`.
    static func standardSize(_ tool: EditorTool, frame type: FrameType) -> CGSize {
        switch tool {
        case .frame: EmptyFrameArt.isPicture(type) ? CGSize(width: 180, height: 120) : type.setsAsBlock ? CGSize(width: 240, height: 200) : CGSize(width: 180, height: 40)
        case .line: CGSize(width: 120, height: 0)
        case .rect: CGSize(width: 100, height: 60)
        case .ellipse: CGSize(width: 60, height: 60)
        case .text: CGSize(width: 140, height: 18)
        case .select: .zero
        }
    }

    /// Place Art…: an image or PDF, embedded, fitted into the component's middle at no more than half its size.
    @discardableResult
    func placeArt(data: Data, name: String) -> UUID? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let k = min(1, draft.width / 2 / img.size.width, draft.height / 2 / img.size.height)
        let w = img.size.width * k, h = img.size.height * k
        let b = Box(x: (draft.width - w) / 2, y: (draft.height - h) / 2, w: w, h: h)
        tool = .select
        return add(.art(ArtElement(box: b, name: name, data: data)), "Place Art")
    }

    // MARK: the component itself

    func setName(_ n: String) { edit("Rename") { name = n } }
    func setColumns(_ n: Int?) { edit("Columns") { draft.columns = n.map { max(1, min(12, $0)) } } }
    /// The gutter, kept small enough that each of the component's columns is at least `ComponentVersion.minColumn` wide.
    func setGutter(_ g: CGFloat?) {
        edit("Gutter") { draft.gutter = g.map { ComponentVersion.clampedGutter($0, width: draft.width, columns: columns) } }
    }

    /// Sets the component's size from the inspector: the right and bottom edges move, the elements stay.
    func setSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        edit("Resize Component") {
            if let width { draft.width = max(Self.minSize.width, width) }
            if let height { draft.height = max(Self.minSize.height, height) }
        }
    }

    static let minSize = CGSize(width: 24, height: 12)

    /// The component's frame on the page put at `r`: its elements keep their place on the page, so pulling the
    /// left edge in trims from the left rather than sliding everything with it.
    func setComponentRect(_ r: CGRect, elementsFrom start: ComponentVersion, origin startOrigin: CGPoint) {
        let dx = startOrigin.x - r.minX, dy = startOrigin.y - r.minY
        var v = start
        v.width = r.width; v.height = r.height
        if dx != 0 || dy != 0 {
            v.elements = start.elements.map { e in var e = e; e.box = Box(e.box.rect.offsetBy(dx: dx, dy: dy)); return e }
        }
        origin = r.origin
        if v != draft { draft = v }
    }

    // MARK: versions

    /// Save: the draft becomes the next version, numbered after the newest, and the base of the one after.
    @discardableResult
    func saveVersion() -> ComponentVersion {
        var v = draft
        v.number = (component.versions.map(\.number).max() ?? 0) + 1
        v.date = Date()
        component.name = name
        component.versions.append(v)
        base = v.number
        draft = v
        return v
    }

    /// The history, the draft and its base: put back when a save's file can't be written.
    var savedState: (component: Component, base: Int?, draft: ComponentVersion) {
        get { (component, base, draft) }
        set { component = newValue.component; base = newValue.base; draft = newValue.draft }
    }

    /// Opens an old version: it replaces the draft and is the base of the next version. Undoable.
    func openVersion(_ n: Int) {
        guard let v = component.version(n) else { return }
        edit("Open v\(n)") { draft = v; base = n }
        selection = nil
    }

    /// The component as it would be saved now: the history, with the draft as a new version if it's edited.
    var componentForSaving: Component {
        var c = component
        c.name = name
        return c
    }

    // MARK: drawing

    /// The page the editor shows: page 1 of an issue with only this component on it, set by the composer as
    /// the pages set it, empty frames as their placeholders and issue fields filled from the open issue.
    func composedPage() -> ComposedPage? {
        var issue = Issue()
        issue.publication = facts.publication; issue.volume = facts.volume; issue.edition = facts.edition; issue.date = facts.date
        issue.stage = .pages
        var c = Component(name: name, versions: [draft]).with(id: component.id)
        c.versions[0].number = 1
        issue.componentVersions = [c]
        // the same page and placement ids on every redraw: the composer caches pages by id, so a fresh id each
        // time would set the page in full and keep every copy for as long as the editor is open
        var page = PageLayout()
        page.id = pageID
        page.isFront = false
        var placed = PlacedComponent(component: component.id, version: 1, frame: Box(rect))
        placed.id = placedID
        page.components = [placed]
        while leadingPages.count < pageIndex { leadingPages.append(UUID()) }
        let ahead = leadingPages.prefix(pageIndex).map { id -> PageLayout in var p = PageLayout(); p.id = id; return p }
        issue.layout = IssueLayout(pages: ahead + [page], columns: pageColumns)
        guard let cp = composer.compose(issue).last else { return nil }
        // the rest of this page is empty by design: no red EMPTY marks for it (the frames' placeholders stay)
        cp.holes = []
        return cp
    }
}
