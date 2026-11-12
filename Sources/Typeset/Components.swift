import AppKit

// A component is a small page: a sized box of frames (typed spots that are empty until something fills them),
// lines, shapes, preset text and placed art, with its own columns. A component has a name and a history of
// versions; an issue keeps a copy of every version its pages use, so a .typeset file stands alone.

/// A colour saved plainly, in sRGB.
struct Paint: Codable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1
    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        self.init(r: s.redComponent, g: s.greenComponent, b: s.blueComponent, a: s.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let ink = Paint(HouseStyle.ink)
    static let red = Paint(HouseStyle.red)
    static let white = Paint(r: 1, g: 1, b: 1)
    static let black = Paint(r: 0, g: 0, b: 0)
}

/// What a frame is for. The type says which part of a dropped story a frame shows, or which fact about the
/// issue fills it on its own.
enum FrameType: String, Codable, CaseIterable, Identifiable {
    // story fields
    case headline, kicker, author, authorTitle, body, image, caption, credit, pullQuote, teaserHeadline, wholeStory
    // where a teased story runs: "Page 5", or "Inside" while it has no page
    case teaserPage
    // an ad, standalone image or graphic
    case ad
    // issue fields, filled for each page without anyone dragging
    case pageNumber, date, volume, edition, desk

    var id: String { rawValue }
    var isIssueField: Bool { [.pageNumber, .date, .volume, .edition, .desk].contains(self) }
    var isStoryField: Bool { !isIssueField && self != .ad }
    /// Set with the story-block code (columns, copyfit, jumps) rather than drawn as one piece of type.
    var setsAsBlock: Bool { self == .body || self == .wholeStory }
    var title: String {
        switch self {
        case .headline: "Headline"; case .kicker: "Kicker"; case .author: "Author"; case .authorTitle: "Author title"
        case .body: "Body"; case .image: "Image"; case .caption: "Caption"; case .credit: "Credit"
        case .pullQuote: "Pull quote"; case .teaserHeadline: "Teaser headline"; case .teaserPage: "Teaser page"; case .wholeStory: "Whole story"
        case .ad: "Ad or graphic"; case .pageNumber: "Page number"; case .date: "Date"; case .volume: "Volume"
        case .edition: "Edition"; case .desk: "Desk"
        }
    }
}

enum TextAlign: String, Codable, Hashable {
    case left, center, right
    var ns: NSTextAlignment { switch self { case .left: .left; case .center: .center; case .right: .right } }
}

/// A typed spot in a component. Linked frames (the same letter) take one story between them.
struct Frame: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: FrameType
    var link: String?                 // "A", "B"…: frames meant for one story
    var box: Box                      // in the component's own points, from its top-left corner
    var size: CGFloat?                // type size; nil is the house style's
    var alignment: TextAlign?         // nil is the house style's
    var color: Paint?                 // the type's colour; nil is ink (the Header's dateline is white on red)
    var dateFormat: String?           // date frames: a DateFormatter format; nil is the folio's
    var outline = true                // image frames: the house hairline around a picture
    var face: String?                 // issue fields and teaser pages: the face; nil is the house folio face
    /// Issue fields: what the frame says around its value. `{page}`, `{date}`, `{volume}`, `{edition}` and `{desk}`
    /// stand for the issue's facts, and a part in square brackets is left out when a fact inside it is empty:
    /// the folio's "[{desk}  •  ]{page}" reads "Sports  •  6", or "6" on a mixed page. Nil shows the value alone.
    var template: String?

    init(type: FrameType, box: Box, link: String? = nil, size: CGFloat? = nil, alignment: TextAlign? = nil,
         color: Paint? = nil, dateFormat: String? = nil, outline: Bool = true, face: String? = nil,
         template: String? = nil) {
        self.type = type; self.box = box; self.link = link; self.size = size; self.alignment = alignment
        self.color = color; self.dateFormat = dateFormat; self.outline = outline; self.face = face
        self.template = template
    }

    static let defaultDateFormat = "EEEE, MMMM d, yyyy"
    static let fieldFace = "Raleway-Bold"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try c.decode(FrameType.self, forKey: .type), box: try c.decode(Box.self, forKey: .box),
                  link: c.value(.link, or: nil as String?), size: c.value(.size, or: nil as CGFloat?),
                  alignment: c.value(.alignment, or: nil as TextAlign?), color: c.value(.color, or: nil as Paint?),
                  dateFormat: c.value(.dateFormat, or: nil as String?), outline: c.value(.outline, or: true),
                  face: c.value(.face, or: nil as String?), template: c.value(.template, or: nil as String?))
        id = c.value(.id, or: UUID())
    }
}

struct LineElement: Codable, Hashable, Identifiable {
    var id = UUID()
    var x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat
    var width: CGFloat = 0.5
    var color = Paint.ink
    init(from: CGPoint, to: CGPoint, width: CGFloat = 0.5, color: Paint = .ink) {
        x1 = from.x; y1 = from.y; x2 = to.x; y2 = to.y; self.width = width; self.color = color
    }
    var from: CGPoint { CGPoint(x: x1, y: y1) }
    var to: CGPoint { CGPoint(x: x2, y: y2) }
}

/// A rectangle or ellipse: filled, stroked, or both.
struct ShapeElement: Codable, Hashable, Identifiable {
    var id = UUID()
    var box: Box
    var fill: Paint?
    var stroke: Paint?
    var strokeWidth: CGFloat = 0.5
    init(box: Box, fill: Paint? = nil, stroke: Paint? = nil, strokeWidth: CGFloat = 0.5) {
        self.box = box; self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth
    }
}

/// Preset text: the same words in every issue ("poly.rpi.edu").
struct TextElement: Codable, Hashable, Identifiable {
    var id = UUID()
    var box: Box
    var text: String
    var face = "Raleway-Bold"
    var size: CGFloat = 12
    var color = Paint.ink
    var alignment = TextAlign.left
    init(box: Box, text: String, face: String = "Raleway-Bold", size: CGFloat = 12, color: Paint = .ink, alignment: TextAlign = .left) {
        self.box = box; self.text = text; self.face = face; self.size = size; self.color = color; self.alignment = alignment
    }
    var attributed: NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = alignment.ns
        return NSAttributedString(string: text, attributes: [.font: HouseStyle.font(face, size), .foregroundColor: color.nsColor, .paragraphStyle: p])
    }
}

/// An image or PDF, embedded so the component travels whole.
struct ArtElement: Codable, Hashable, Identifiable {
    var id = UUID()
    var box: Box
    var name: String                  // the file it came from, for the editor
    var data: Data
    init(box: Box, name: String, data: Data) { self.box = box; self.name = name; self.data = data }

    /// Hashes the art's bytes by sample (its length and a few hundred bytes from its start, middle and end), not
    /// in full: the editor and the composer's page cache hash components on every redraw, and Data hashes every
    /// byte, which for a few megabytes of embedded picture is slow enough to see. Equality still compares it all.
    func hash(into h: inout Hasher) {
        h.combine(id); h.combine(box); h.combine(name)
        h.combine(Self.sample(data))
    }

    static func sample(_ d: Data) -> Int {
        var h = Hasher()
        h.combine(d.count)
        let n = 128
        if d.count <= n * 3 { h.combine(d) } else {
            let s = d.startIndex, mid = s + d.count / 2
            h.combine(d[s ..< s + n]); h.combine(d[mid ..< mid + n]); h.combine(d[d.endIndex - n ..< d.endIndex])
        }
        return h.finalize()
    }
}

/// One thing in a component. Saved flat, with a `kind` key, so a kind this build doesn't know is dropped on its own.
enum Element: Hashable, Identifiable {
    case frame(Frame), line(LineElement), rect(ShapeElement), ellipse(ShapeElement), text(TextElement), art(ArtElement)

    var id: UUID {
        switch self {
        case .frame(let f): f.id; case .line(let l): l.id; case .rect(let s), .ellipse(let s): s.id
        case .text(let t): t.id; case .art(let a): a.id
        }
    }
    var frame: Frame? { if case .frame(let f) = self { f } else { nil } }
}

extension Element: Codable {
    private enum Kind: String, Codable { case frame, line, rect, ellipse, text, art }
    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind)
        switch kind {
        case .frame: self = .frame(try Frame(from: decoder))
        case .line: self = .line(try LineElement(from: decoder))
        case .rect: self = .rect(try ShapeElement(from: decoder))
        case .ellipse: self = .ellipse(try ShapeElement(from: decoder))
        case .text: self = .text(try TextElement(from: decoder))
        case .art: self = .art(try ArtElement(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .frame(let v): try c.encode(Kind.frame, forKey: .kind); try v.encode(to: encoder)
        case .line(let v): try c.encode(Kind.line, forKey: .kind); try v.encode(to: encoder)
        case .rect(let v): try c.encode(Kind.rect, forKey: .kind); try v.encode(to: encoder)
        case .ellipse(let v): try c.encode(Kind.ellipse, forKey: .kind); try v.encode(to: encoder)
        case .text(let v): try c.encode(Kind.text, forKey: .kind); try v.encode(to: encoder)
        case .art(let v): try c.encode(Kind.art, forKey: .kind); try v.encode(to: encoder)
        }
    }
}

/// One state of a component. Versions are numbered from 1 and never change once an issue has used them.
struct ComponentVersion: Codable, Hashable {
    var number = 1
    var width: CGFloat
    var height: CGFloat
    var columns: Int?                 // nil: the page's
    var gutter: CGFloat?              // nil: the page's
    var elements: [Element] = []
    var date = Date()

    init(number: Int = 1, width: CGFloat, height: CGFloat, columns: Int? = nil, gutter: CGFloat? = nil, elements: [Element] = [], date: Date = Date()) {
        self.number = number; self.width = width; self.height = height; self.columns = columns; self.gutter = gutter
        self.elements = elements; self.date = date
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var frames: [Frame] { elements.compactMap(\.frame) }

    /// The narrowest a component's column may be: a gutter that would leave less is cut down to fit.
    static let minColumn: CGFloat = 12
    /// A gutter that leaves each of `columns` columns across `width` at least `minColumn` wide (never below 0),
    /// so no gutter, typed in or read from a file, reaches the composer as a negative column.
    static func clampedGutter(_ g: CGFloat, width: CGFloat, columns: Int) -> CGFloat {
        guard g.isFinite else { return HouseStyle.gutter }
        guard columns > 1 else { return max(0, g) }
        return max(0, min(g, (width - CGFloat(columns) * minColumn) / CGFloat(columns - 1)))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(number: c.value(.number, or: 1), width: try c.decode(CGFloat.self, forKey: .width), height: try c.decode(CGFloat.self, forKey: .height),
                  columns: c.value(.columns, or: nil as Int?), gutter: c.value(.gutter, or: nil as CGFloat?),
                  elements: c.lossy(.elements), date: c.value(.date, or: Date()))
    }
}

struct Component: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var versions: [ComponentVersion] = []

    init(name: String, versions: [ComponentVersion] = []) { self.name = name; self.versions = versions }

    var latest: ComponentVersion? { versions.max { $0.number < $1.number } }
    func version(_ n: Int) -> ComponentVersion? { versions.first { $0.number == n } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // a component needs its id (placements point at it) and its name; a version that can't be read is dropped alone
        self.init(name: try c.decode(String.self, forKey: .name), versions: c.lossy(.versions))
        id = try c.decode(UUID.self, forKey: .id)
    }
}

/// What has been dropped on a frame: a story, one of its pictures, or an ad. Keyed by the frame, or by its
/// link letter when the frame is linked (every frame with that letter shares the one story).
struct Fill: Codable, Hashable {
    var frame: Frame.ID?
    var link: String?
    var article: Article.ID?
    var photo: Photo.ID?
    var extra: Extra.ID?
    var focusX: CGFloat = 0.5         // image frames: which part of the picture shows, as for an inset
    var focusY: CGFloat = 0.5

    init(frame: Frame.ID? = nil, link: String? = nil, article: Article.ID? = nil, photo: Photo.ID? = nil, extra: Extra.ID? = nil) {
        self.frame = frame; self.link = link; self.article = article; self.photo = photo; self.extra = extra
    }
    var focus: CGPoint { CGPoint(x: focusX, y: focusY) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frame: c.value(.frame, or: nil as Frame.ID?), link: c.value(.link, or: nil as String?),
                  article: c.value(.article, or: nil as Article.ID?), photo: c.value(.photo, or: nil as Photo.ID?),
                  extra: c.value(.extra, or: nil as Extra.ID?))
        focusX = c.value(.focusX, or: 0.5).clamped(0, 1); focusY = c.value(.focusY, or: 0.5).clamped(0, 1)
    }
}

/// A component on a page: which version it shows (or a custom copy, edited in place), where it sits, and what
/// its frames hold. The frame may differ from the version's size: the boxes stretch with it, the type doesn't.
struct PlacedComponent: Codable, Hashable, Identifiable {
    var id = UUID()
    var component: Component.ID
    var version: Int
    var custom: ComponentVersion?     // edited in place: "Header custom" instead of "Header v3"
    var frame: Box
    var fills: [Fill] = []
    /// Duplicate on All (Inside) Pages marks a placement as repeating: Add Page puts it on new pages too (Templates.swift).
    var repeats: Repeat?

    init(component: Component.ID, version: Int, frame: Box, custom: ComponentVersion? = nil, fills: [Fill] = [], repeats: Repeat? = nil) {
        self.component = component; self.version = version; self.frame = frame; self.custom = custom; self.fills = fills
        self.repeats = repeats
    }

    /// The fill a frame takes: by its link letter when it has one, else by the frame itself.
    func fill(for f: Frame) -> Fill? {
        if let l = f.link, let x = fills.first(where: { $0.link == l }) { return x }
        return fills.first { $0.frame == f.id }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(component: try c.decode(Component.ID.self, forKey: .component), version: c.value(.version, or: 1),
                  frame: try c.decode(Box.self, forKey: .frame), custom: c.value(.custom, or: nil as ComponentVersion?), fills: c.lossy(.fills),
                  repeats: c.value(.repeats, or: nil as Repeat?))
        id = c.value(.id, or: UUID())
    }
}

extension Issue {
    /// The version a placed component draws: its custom copy, or the copy the issue keeps.
    func version(of p: PlacedComponent) -> ComponentVersion? {
        p.custom ?? componentVersions.first { $0.id == p.component }?.version(p.version)
    }
    func componentName(_ id: Component.ID) -> String? { componentVersions.first { $0.id == id }?.name }

    /// Keeps a copy of one version of a component, so the issue draws it with no component file around.
    mutating func embed(_ c: Component, version n: Int) {
        guard let v = c.version(n) else { return }
        if let i = componentVersions.firstIndex(where: { $0.id == c.id }) {
            componentVersions[i].name = c.name
            if !componentVersions[i].versions.contains(where: { $0.number == n }) { componentVersions[i].versions.append(v) }
        } else {
            componentVersions.append(Component(name: c.name, versions: [v]).with(id: c.id))
        }
    }

    /// Places a version of a component on a page, embedding it. Returns the placement's id.
    @discardableResult
    mutating func place(_ c: Component, version n: Int, on page: Int, at origin: CGPoint, fills: [Fill] = []) -> PlacedComponent.ID? {
        guard let v = c.version(n), layout != nil, layout!.pages.indices.contains(page) else { return nil }
        embed(c, version: n)
        let p = PlacedComponent(component: c.id, version: n, frame: Box(x: origin.x, y: origin.y, w: v.width, h: v.height), fills: fills)
        layout!.pages[page].components.append(p)
        return p.id
    }

    /// Drops the copies no page uses any more.
    mutating func pruneComponentVersions() {
        var used: Set<String> = []
        for page in layout?.pages ?? [] { for p in page.components { used.insert("\(p.component)|\(p.version)") } }
        componentVersions = componentVersions.compactMap { c in
            var c = c
            c.versions.removeAll { !used.contains("\(c.id)|\($0.number)") }
            return c.versions.isEmpty ? nil : c
        }
    }
}

extension Component {
    func with(id: Component.ID) -> Component { var c = self; c.id = id; return c }
}

/// A placed component worked out on its page: the version it draws, its frame, how its boxes scale, and its columns.
struct ResolvedComponent {
    var placed: PlacedComponent
    var version: ComponentVersion
    var frame: CGRect
    var columns: Int
    var gutter: CGFloat

    init?(_ placed: PlacedComponent, in issue: Issue, pageColumns: Int) {
        guard let v = issue.version(of: placed), v.width > 0, v.height > 0 else { return nil }
        self.placed = placed; version = v; frame = placed.frame.rect
        columns = max(1, v.columns ?? pageColumns)
        gutter = ComponentVersion.clampedGutter(v.gutter ?? HouseStyle.gutter, width: frame.width, columns: columns)
    }

    var scaleX: CGFloat { frame.width / version.width }
    var scaleY: CGFloat { frame.height / version.height }
    /// A box in the component's points, on the page.
    func rect(_ b: Box) -> CGRect {
        CGRect(x: frame.minX + b.x * scaleX, y: frame.minY + b.y * scaleY, width: b.w * scaleX, height: b.h * scaleY)
    }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * scaleX, y: frame.minY + p.y * scaleY) }

    /// The component's columns, on the page.
    var columnRects: [CGRect] {
        let w = (frame.width - CGFloat(columns - 1) * gutter) / CGFloat(columns)
        return (0..<columns).map { CGRect(x: frame.minX + CGFloat($0) * (w + gutter), y: frame.minY, width: w, height: frame.height) }
    }
    /// How many of the component's columns a box lies across: what a body frame sets in.
    func columnsSpanned(by b: Box) -> Int {
        let r = rect(b)
        return max(1, columnRects.filter { $0.minX < r.maxX - 1 && $0.maxX > r.minX + 1 }.count)
    }
}
