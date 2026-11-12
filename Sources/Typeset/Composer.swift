import AppKit
import ObjCTry
import CoreText

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Columns

/// A column that sets body lines on a baseline grid and steps around pictures, the way InDesign's text wrap does:
/// a line that can't get at least `minimumFraction` of the column beside an obstacle jumps below it.
final class FlowContainer: NSTextContainer {
    var obstacles: [CGRect] = []          // container coordinates
    var pitch: CGFloat?                   // baseline grid; nil for display type
    var minimumFraction: CGFloat = 0.5
    var slack: CGFloat = 0                // the empty line gap at the foot of a line, which obstacles may share

    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposed: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        remainingRect?.pointee = .zero
        // TextKit proposes the font's natural line height; body lines take exactly one grid step
        return place(y: proposed.minY, height: pitch ?? proposed.height)
    }

    /// Where a line of the given height proposed at `y` actually goes; `.zero` when the column is full.
    func place(y start: CGFloat, height h: CGFloat) -> NSRect {
        let width = size.width
        var y = max(0, start)
        while true {
            if let p = pitch { y = ((y - 0.01) / p).rounded(.up) * p }
            if y + h > size.height + 0.01 { return .zero }
            // a hundredth of a point either way: a picture put on the line grid ends exactly where a line starts, and
            // rounding in page coordinates mustn't push that line, and the text under the caption, a line lower
            let hits = obstacles.filter { $0.minY < y + h - slack - 0.01 && $0.maxY > y + 0.01 && $0.minX < width && $0.maxX > 0 }
            if hits.isEmpty { return NSRect(x: 0, y: y, width: width, height: h) }
            // display type (no grid) under something that only clips the top of the line, such as a caption above the
            // headline reaching a few points down: the line goes under it whole rather than squeezed beside it
            if pitch == nil, let low = hits.map(\.maxY).max(), low - y < h * 0.4 { y = low; continue }
            if let best = Self.free(width: width, minus: hits).max(by: { $0.width < $1.width }),
               best.width >= width * minimumFraction {
                return NSRect(x: best.lo, y: y, width: best.width, height: h)
            }
            y = max(y + 0.5, hits.map(\.maxY).min()!)
        }
    }

    /// How many lines of the given height fit, without setting any text.
    func lineCapacity(height h: CGFloat) -> [CGFloat] {
        var ys: [CGFloat] = []
        var y: CGFloat = 0
        while true {
            let r = place(y: y, height: h)
            if r == .zero { return ys }
            ys.append(r.minY)
            y = r.maxY
        }
    }

    struct Span { var lo: CGFloat; var hi: CGFloat; var width: CGFloat { hi - lo } }

    static func free(width: CGFloat, minus hits: [CGRect]) -> [Span] {
        var free = [Span(lo: 0, hi: width)]
        for o in hits {
            free = free.flatMap { s -> [Span] in
                guard o.maxX > s.lo, o.minX < s.hi else { return [s] }
                var out: [Span] = []
                if o.minX > s.lo { out.append(Span(lo: s.lo, hi: o.minX)) }
                if o.maxX < s.hi { out.append(Span(lo: o.maxX, hi: s.hi)) }
                return out
            }
        }
        return free
    }
}

// MARK: - Composed pages

enum DrawOp {
    case fill(CGRect, NSColor)
    case line(CGPoint, CGPoint, CGFloat, NSColor)
    case frame(CGRect, CGFloat, NSColor)
    case text(NSAttributedString, CGRect)
    case flow(NSLayoutManager, NSTextContainer, CGPoint)
    case image(NSImage, CGRect, CGFloat, CGPoint)   // filled and cropped to the frame about a focus, with an optional stroke
    case fitted(NSImage, CGRect)              // scaled to fit inside the frame, whole
    case art(NSImage, CGRect)                  // vector art, drawn as is
    case missing(CGRect)
    case path(NSBezierPath, NSColor?, NSColor?, CGFloat)   // a component's shape: filled, stroked, or both
    case placeholder(CGRect, FrameType)        // an empty frame: drawn on screen only (markers), never printed
}

/// One page, set and ready to draw at any scale (screen, thumbnail or PDF).
final class ComposedPage {
    struct Overset { var at: CGPoint; var lines: Int; var story: String }
    struct Blank {                                                              // blank lines a story can't fill, even set loose
        var at: CGPoint; var lines: Int; var story: String
        var orphan: Int? = nil                                                  // set when the story ended on this page, before the block
    }
    struct Hole { var rect: CGRect; var area: Double }                          // page area nothing covers, square inches

    let number: Int
    let grid: Grid
    let isFront: Bool
    var section = ""
    var ops: [DrawOp] = []
    var keep: [NSTextStorage] = []                    // owns the layout managers the .flow ops draw from
    var insetFrames: [Inset.ID: CGRect] = [:]          // picture plus caption, for hit testing
    var pictureFrames: [Inset.ID: CGRect] = [:]
    var storyFrames: [StoryBlock.ID: CGRect] = [:]
    var blockResults: [StoryBlock.ID: Composer.BlockResult] = [:]
    var componentFrames: [PlacedComponent.ID: CGRect] = [:]                     // placed components, for hit testing
    var componentBlockResults: [PlacedComponent.ID: [Frame.ID: Composer.BlockResult]] = [:]   // stories set in body and whole-story frames
    var oversets: [Overset] = []                                                // never, now: text that doesn't fit goes online
    var online: [Overset] = []                                                  // blocks ending "Read the rest at poly.rpi.edu."

    var blanks: [Blank] = []
    /// Some story here is set at its last fit while the exact one is worked out: its blank-line and online marks
    /// would flicker, so they wait.
    var provisional = false
    var holes: [Hole] = []
    var hasProblems: Bool { !oversets.isEmpty || !blanks.isEmpty || !holes.isEmpty }
    var emptyArea: Double { holes.reduce(0) { $0 + $1.area } }
    var incoming: [Article.ID: Int] = [:]              // where each story's body stands as this page begins

    init(number: Int, grid: Grid, isFront: Bool) {
        self.number = number; self.grid = grid; self.isFront = isFront
    }

    /// Draw into the current graphics context, which must be flipped with page points as units.
    /// `markers` adds the red problem marks (overset text, blank lines, holes) for the screen, never for print.
    func draw(guides: Bool, markers: Bool = false) {
        NSColor.white.setFill()
        CGRect(origin: .zero, size: HouseStyle.page).fill()
        if guides { drawGuides() }
        for op in ops {
            switch op {
            case let .fill(r, c):
                c.setFill(); r.fill()
            case let .line(a, b, w, c):
                let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = w
                c.setStroke(); p.stroke()
            case let .frame(r, w, c):
                let p = NSBezierPath(rect: r.insetBy(dx: w / 2, dy: w / 2)); p.lineWidth = w
                c.setStroke(); p.stroke()
            case let .text(s, r):
                s.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            case let .flow(lm, tc, origin):
                let g = lm.glyphRange(for: tc)
                lm.drawBackground(forGlyphRange: g, at: origin)
                lm.drawGlyphs(forGlyphRange: g, at: origin)
            case let .image(img, r, stroke, focus):
                Self.drawFilled(img, in: r, focus: focus)
                if stroke > 0 {
                    let p = NSBezierPath(rect: r.insetBy(dx: stroke / 2, dy: stroke / 2)); p.lineWidth = stroke
                    HouseStyle.ink.setStroke(); p.stroke()
                }
            case let .fitted(img, r):
                Self.drawFitted(img, in: r)
            case let .art(img, r):
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case let .missing(r):
                NSColor(white: 0.9, alpha: 1).setFill(); r.fill()
            case let .path(p, fill, stroke, w):
                if let fill { fill.setFill(); p.fill() }
                if let stroke, w > 0 { p.lineWidth = w; stroke.setStroke(); p.stroke() }
            case let .placeholder(r, type):
                if markers { EmptyFrameArt.draw(type, in: r) }
            }
        }
        if markers { drawMarkers(fitsSettled: !provisional) }
    }

    /// A picture drawn whole inside a frame, centred: an ad or graphic.
    static func drawFitted(_ img: NSImage, in r: CGRect) {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return }
        let k = min(r.width / s.width, r.height / s.height)
        let f = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        img.draw(in: f, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                 hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    static func drawFilled(_ img: NSImage, in r: CGRect, focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let s = img.size
        guard s.width > 0, s.height > 0, r.width > 0, r.height > 0 else { return }
        let src = fillSource(image: s, frame: r.size, focus: focus)
        // NSImage's source rect has its origin at the bottom: the top of the picture is y = height - (top + h)
        let flipped = CGRect(x: src.minX, y: s.height - src.maxY, width: src.width, height: src.height)
        img.draw(in: r, from: flipped, operation: .sourceOver, fraction: 1, respectFlipped: true,
                 hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    /// The part of a picture (top-left origin, picture points) that fills a frame: scaled to cover it, then the
    /// hidden span on the one axis with any slides with the focus, 0 keeping the first edge and 1 the last.
    static func fillSource(image s: CGSize, frame: CGSize, focus: CGPoint) -> CGRect {
        let scale = max(frame.width / s.width, frame.height / s.height)
        let w = frame.width / scale, h = frame.height / scale
        return CGRect(x: (s.width - w) * focus.x.clamped(0, 1), y: (s.height - h) * focus.y.clamped(0, 1), width: w, height: h)
    }

    private func drawGuides() {
        let top = isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        let margins = NSBezierPath(rect: CGRect(x: HouseStyle.margin, y: top, width: HouseStyle.liveWidth, height: HouseStyle.bottom - top))
        margins.lineWidth = 0.5
        NSColor(srgbRed: 0.93, green: 0.3, blue: 0.75, alpha: 0.55).setStroke()
        margins.stroke()
        let cols = NSBezierPath()
        for i in 0..<grid.columns {
            for x in [grid.x(i), grid.x(i) + grid.colWidth] where x > HouseStyle.margin + 0.5 && x < HouseStyle.margin + HouseStyle.liveWidth - 0.5 {
                cols.move(to: CGPoint(x: x, y: top)); cols.line(to: CGPoint(x: x, y: HouseStyle.bottom))
            }
        }
        cols.lineWidth = 0.5
        NSColor(srgbRed: 0.5, green: 0.4, blue: 0.95, alpha: 0.45).setStroke()
        cols.stroke()
    }

    private func drawMarkers(fitsSettled: Bool) {
        let red = NSColor.systemRed
        for h in holes {
            red.withAlphaComponent(0.07).setFill(); h.rect.fill()
            let hatch = NSBezierPath()
            var x = h.rect.minX - h.rect.height
            while x < h.rect.maxX {
                hatch.move(to: CGPoint(x: max(x, h.rect.minX), y: x < h.rect.minX ? h.rect.minY + (h.rect.minX - x) : h.rect.minY))
                let end = CGPoint(x: min(x + h.rect.height, h.rect.maxX), y: min(h.rect.maxY, h.rect.minY + (min(x + h.rect.height, h.rect.maxX) - x)))
                hatch.line(to: end)
                x += 14
            }
            hatch.lineWidth = 0.5
            red.withAlphaComponent(0.25).setStroke(); hatch.stroke()
            let box = NSBezierPath(rect: h.rect.insetBy(dx: 0.5, dy: 0.5))
            box.lineWidth = 1; box.setLineDash([5, 3], count: 2, phase: 0)
            red.setStroke(); box.stroke()
            let label = NSAttributedString(string: String(format: "EMPTY · %.1f in²", h.area), attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: red])
            label.draw(at: CGPoint(x: h.rect.minX + 5, y: h.rect.minY + 4))
        }
        for b in blanks where fitsSettled {
            let box = CGRect(x: b.at.x - 9, y: b.at.y - 9, width: 9, height: 9)
            NSColor.white.setFill(); box.fill()
            red.setStroke()
            let p = NSBezierPath(rect: box); p.lineWidth = 1; p.stroke()
            let minus = NSBezierPath()
            minus.move(to: CGPoint(x: box.minX + 2, y: box.midY)); minus.line(to: CGPoint(x: box.maxX - 2, y: box.midY))
            minus.lineWidth = 1; minus.stroke()
            let text = b.orphan.map { "nothing left to run here · story ended on page \($0)" } ?? "\(b.lines) blank lines"
            let label = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: red])
            label.draw(at: CGPoint(x: box.minX - label.size().width - 4, y: box.minY - 0.5))
        }
        for o in online where fitsSettled {
            let orange = NSColor.systemOrange
            let box = CGRect(x: o.at.x - 9, y: o.at.y + 3, width: 9, height: 9)      // just under the block, clear of the printed line
            NSColor.white.setFill(); box.fill()
            orange.setStroke()
            let p = NSBezierPath(ovalIn: box); p.lineWidth = 1; p.stroke()
            let label = NSAttributedString(string: "\(o.lines) lines online", attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: orange])
            label.draw(at: CGPoint(x: box.minX - label.size().width - 4, y: box.minY - 0.5))
        }
        for o in oversets {
            let box = CGRect(x: o.at.x - 9, y: o.at.y - 9, width: 9, height: 9)
            NSColor.white.setFill(); box.fill()
            NSColor.systemRed.setStroke()
            let p = NSBezierPath(rect: box); p.lineWidth = 1; p.stroke()
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: box.midX, y: box.minY + 2)); plus.line(to: CGPoint(x: box.midX, y: box.maxY - 2))
            plus.move(to: CGPoint(x: box.minX + 2, y: box.midY)); plus.line(to: CGPoint(x: box.maxX - 2, y: box.midY))
            plus.lineWidth = 1; plus.stroke()
            let label = NSAttributedString(string: "\(o.lines) lines overset", attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.systemRed])
            let w = label.size().width
            label.draw(at: CGPoint(x: box.minX - w - 4, y: box.minY - 0.5))
        }
    }
}

// MARK: - Composer

/// Sets type for a laid-out issue with TextKit: headlines, bylines, body in columns around pictures,
/// captions, jump lines, the folio and the front-page furniture.
/// Copyfitting: small, even changes to spacing that let a story fill its space exactly, the way a
/// composing editor tightens or loosens a story. `level` runs from -1 (tightest) to +1 (loosest) in the
/// comfortable range nobody notices; 0 is the house style. Word spacing gives first, then tracking and leading;
/// glyph scaling only past half way. Past ±1, up to ±2, is the emergency range: the same levers pushed about
/// twice as far, used only when the comfortable range can't make a story fit.
struct Fit: Hashable {
    var level: Double = 0
    /// Runs of words set at a level of their own, by paragraph index: the composing room's trick of tracking the
    /// end of a paragraph to pull a line back or gain one, with the rest of the story untouched. Leading stays the
    /// story's own, so baselines hold.
    var local: [Int: Composer.Tail] = [:]
    init(level: Double = 0, local: [Int: Composer.Tail] = [:]) { self.level = level; self.local = local }
    static let neutral = Fit()
    static let comfortable = 1.0
    static let limit = 2.0
    /// The strongest setting anywhere in the story, signed: what a reader might notice.
    var strongest: Double {
        local.values.reduce(level) { abs($1.level) > abs($0) ? $1.level : $0 }
    }
    /// How far past the comfortable range this is, 0 … 1.
    private var beyond: Double { max(0, abs(level) - Self.comfortable) }
    private var within: Double { level.clamped(-Self.comfortable, Self.comfortable) }
    // Within the comfortable range the spacing levers go as far as Adobe and Bringhurst call acceptable: word
    // spacing to InDesign's 133% maximum, glyph scaling to the 97–103% Adobe allows, tracking a touch past "barely
    // noticeable". Leading stays within a point, since it shows across columns. Footprint about -10% … +13%.
    var leading: CGFloat {                                                                                 // 14.0 … 14.9, then 13.6 … 15.4
        HouseStyle.leading + CGFloat(within < 0 ? 0.4 * within : 0.5 * within) + CGFloat((level < 0 ? -0.4 : 0.5) * beyond)
    }
    var tracking: CGFloat {                                                                                // -15 … +12 /1000 em, then -25 … +20
        CGFloat((within < 0 ? 15 * within : 12 * within) + (level < 0 ? -10 : 8) * beyond) / 1000 * HouseStyle.bodySize
    }
    var wordSpace: CGFloat {                                                                               // 75% … 133% of a space, then 65% … 145%
        let w = within < 0 ? 0.25 * within : 0.33 * within
        return CGFloat(w + (level < 0 ? -0.10 : 0.12) * beyond)
    }
    var glyphScale: CGFloat {
        let t = max(0, abs(within) - 0.5) / 0.5
        return 1 + CGFloat((level < 0 ? -1 : 1) * (0.03 * t + 0.02 * beyond))                              // 97% … 103%, then 95% … 105%
    }
    var isEmergency: Bool { abs(level) > Self.comfortable + 0.001 }
    var key: Int {
        guard !local.isEmpty else { return Int((level * 100).rounded()) }
        var h = Hasher()
        h.combine(Int((level * 100).rounded()))
        for (i, t) in local.sorted(by: { $0.key < $1.key }) { h.combine(i); h.combine(t.from); h.combine(Int((t.level * 100).rounded())) }
        return h.finalize()
    }
}

/// How a story came out of copyfitting, for the editor: areas are square inches.
struct FitInfo {
    var level: Double
    var percent: Double        // change in the text's footprint against the house style: -0.04 is 4% tighter
    var area: Double           // the space the blocks carrying its text take up
    var spare: Double          // what it could still give up, set as tight as allowed (blank lines included)
    var short: Double          // what it still needs, set as tight as allowed
    var used: Int
    var room: Int              // lines the blocks carrying text could hold
    var overset: Int
    var blank = 0              // lines left unfilled in those blocks, at this setting
    var orphans = 0            // blocks the story never reaches: it ends before them
    var uniform = 0.0          // the setting the whole story shares; 0 is house style
    var places = 0             // runs of words set on their own to make the story come out exactly
    var localLines = 0         // lines they gained (+) or lost (−)
}

final class Composer {
    struct BlockResult {
        var start: Int; var end: Int; var total: Int
        var bottom: CGFloat; var jumped: Bool
        var used = 0                    // body lines set in this block
        var room = 0                    // body lines the block could hold
        var oversetLines = 0            // lines that didn't fit: read online, when this is the story's last block
        var online = false              // the block ends with "Read the rest at poly.rpi.edu."
        var hyphens: [Int] = []         // where a line broke inside a word, as indices into the story's body (set pages only)

        var continuedFrom: Int?
        var jumpTo: Int?
        var byline: CGRect?             // where the byline sits, for the handle on the page
        var inkTop: CGFloat = 0         // the first ink in the block: the capitals of the kicker or headline
        var inkBottom: CGFloat = 0      // the last: the bottom of the last line set
        var empty: Int { max(0, room - used) }
    }

    /// The parts of a story module that don't depend on its text: where the body goes and what it must avoid.
    struct BlockGeometry {
        var headline: (storage: NSTextStorage, manager: NSLayoutManager, container: FlowContainer)?
        var bodyTop: CGFloat
        var columns: [CGRect]
        var avoid: [CGRect]                // page coordinates, including the byline and jump line
        var byline: CGRect?
        var kicker: CGRect?
        var headTop: CGFloat = 0           // where the display type starts: the block's top, or lower when the byline is held level with a neighbour's
        var jump: CGRect
        var headlineSize: CGFloat = 0      // the size the headline is set at: the block's, or smaller to keep it out of a picture's way
    }

    static let language = NSAttributedString.Key(kCTLanguageAttributeName as String)
    var artImages: [ArtElement.ID: (hash: Int, image: NSImage)] = [:]     // a component's embedded art, decoded once

    private var bodies: [String: (key: Int, text: NSAttributedString)] = [:]
    private var extras: [Extra.ID: Extra] = [:]
    /// The issue last composed: where `obstacles` finds the versions of a page's placed components.
    var componentSource: Issue?
    private struct FitEntry { var key: Int; var fit: Fit; var info: FitInfo; var quick: Bool; var tight: Measure }
    private var fitCache: [Article.ID: FitEntry] = [:]
    /// The last composition, handed back as long as the issue hasn't changed: a screen update asks several times.
    private var memo: [Bool: (issue: Issue, deferred: Bool, generation: Int, pages: [ComposedPage], fits: [Article.ID: FitInfo], settings: [Article.ID: Fit])] = [:]
    /// Background copyfitting (the app; nil in the headless harness). With it, what the canvas draws never waits for
    /// a fit: a story whose blocks changed is set at its last fit straight away while the exact fit is worked out on
    /// another thread, then swapped in. InDesign draws the same way, composing behind the screen.
    var worker: FitWorker?
    /// Told on the main thread when background fits have come in, so the screen redraws.
    var onFitsReady: (() -> Void)?
    /// Counts fits that came in from the background; part of the memo's key.
    private(set) var generation = 0
    /// How each placed story is copyfit in the current layout.
    private(set) var fits: [Article.ID: FitInfo] = [:]
    /// The setting each placed story is composed at: the uniform level and the runs set on their own.
    private(set) var settings: [Article.ID: Fit] = [:]
    /// While something is being dragged, stories are refit quickly from their last setting; the full search runs
    /// when the drag ends.
    var deferFits = false
    /// Whether the pointer is really down. A drag that ends without the canvas hearing about it would otherwise
    /// leave the quick fits in force for good; the harness overrides this to fake a pointer held down.
    static var pointerDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Told when a drag turns out to have ended without the canvas hearing: the store closes its edit session.
    var onLostDrag: (() -> Void)?
    private var dragging: Bool {
        if deferFits, !Self.pointerDown() {
            deferFits = false
            dragLog.info("drag ended without notice; refitting")
            onLostDrag?()
        }
        return deferFits
    }
    private var pageCache: [UUID: (key: Int, page: ComposedPage, out: [Article.ID: Int])] = [:]
    private var images: [String: NSImage] = [:]
    private var headlineHeights: [String: CGFloat] = [:]
    private var lineCounts: [String: Int] = [:]
    private var textHeights: [String: CGFloat] = [:]

    // MARK: pictures

    func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        guard let url = IssueStore.imageURL(for: path), let img = NSImage(contentsOf: url) else { return nil }
        images[path] = img
        return img
    }

    /// Width over height, from the picture's pixels.
    func aspect(_ photo: Photo) -> CGFloat { aspect(path: photo.path) }

    func aspect(path: String) -> CGFloat {
        guard let img = image(path) else { return 1.5 }
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
        }
        return img.size.height > 0 ? img.size.width / img.size.height : 1.5
    }

    // MARK: styles

    /// The Body style. A story's first paragraph is set flush left (`first`); every later one is indented.
    static func bodyStyle(leading: CGFloat = HouseStyle.leading, first: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .justified
        p.firstLineHeadIndent = first ? 0 : HouseStyle.indent
        p.minimumLineHeight = leading
        p.maximumLineHeight = leading
        p.hyphenationFactor = 0.95
        return p
    }

    static func continuedAttributes(_ fit: Fit) -> [NSAttributedString.Key: Any] {
        [.font: HouseStyle.font("MinionPro-It", HouseStyle.bodySize), .foregroundColor: HouseStyle.ink,
         .paragraphStyle: bodyStyle(leading: fit.leading), language: "en", .kern: fit.tracking, .expansion: log(fit.glyphScale)]
    }

    static let spaceWidth: CGFloat = (" " as NSString).size(withAttributes: [.font: HouseStyle.bodyFont]).width

    /// A story's body as the paper sets it, tightened or loosened by `fit`.
    func body(_ a: Article, fit: Fit = .neutral) -> NSAttributedString {
        let key = a.body.hashValue
        let id = "\(a.id)|\(fit.key)"
        if let b = bodies[id], b.key == key { return b.text }
        let s = NSMutableAttributedString(attributedString: Markup.attributed(Self.paragraphs(of: a), size: HouseStyle.bodySize))
        let all = NSRange(location: 0, length: s.length)
        s.addAttributes([.paragraphStyle: Self.bodyStyle(leading: fit.leading), .foregroundColor: HouseStyle.ink, .ligature: 1, Self.language: "en"], range: all)
        if let first = Self.paragraphRanges(s.string).first {      // the first paragraph flush left
            s.addAttribute(.paragraphStyle, value: Self.bodyStyle(leading: fit.leading, first: true), range: first)
        }
        if fit.level != 0 { Self.space(s, range: all, as: fit) }
        if !fit.local.isEmpty {
            let ranges = Self.paragraphRanges(s.string)
            for (i, t) in fit.local where i < ranges.count && t.from < ranges[i].length {
                let r = ranges[i]
                Self.space(s, range: NSRange(location: r.location + t.from, length: r.length - t.from), as: Fit(level: t.level))
            }
        }
        bodies[id] = (key, s)
        return s
    }

    /// A story's paragraphs as set: trimmed, empty ones dropped.
    static func paragraphs(of a: Article) -> [String] { a.body.map { HouseStyle.keepTogether($0.trimmed) }.filter { !$0.isEmpty } }

    /// Where each paragraph lies in a body joined with newlines.
    static func paragraphRanges(_ string: String) -> [NSRange] {
        let ns = string as NSString
        var out: [NSRange] = []
        var start = 0
        for i in 0..<ns.length where ns.character(at: i) == 0x0A {
            out.append(NSRange(location: start, length: i - start)); start = i + 1
        }
        out.append(NSRange(location: start, length: ns.length - start))
        return out
    }

    /// Tracking, glyph scaling and word spacing for a setting, over a range. Word spacing: the space characters
    /// give or take a share of their own width.
    private static func space(_ s: NSMutableAttributedString, range: NSRange, as fit: Fit) {
        s.addAttributes([.kern: fit.tracking, .expansion: log(fit.glyphScale)], range: range)
        let ns = s.string as NSString
        for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 0x20 {
            s.addAttribute(.kern, value: fit.tracking + fit.wordSpace * Self.spaceWidth, range: NSRange(location: i, length: 1))
        }
    }

    /// A run of words at the end of a paragraph set at a level of its own: from character `from` of the
    /// paragraph (0 is the whole paragraph) to its end.
    struct Tail: Hashable { var from: Int; var level: Double }

    private var paragraphLayouts: [String: [NSRange]] = [:]     // line ranges of a paragraph set alone
    private var tailLines: [String: Int] = [:]

    /// A paragraph set alone at a base level, with its tail from `from` at a level of its own.
    private var paragraphTexts: [String: NSAttributedString] = [:]      // a paragraph at a base setting, before any tail

    private func paragraphText(_ p: String, base: Double, tail: Tail?, first: Bool) -> NSAttributedString {
        let key = "\(p.hashValue)|\(Int((base * 100).rounded()))|\(first)"
        let based: NSAttributedString
        if let b = paragraphTexts[key] { based = b } else {
            let s = NSMutableAttributedString(attributedString: Markup.attributed([p], size: HouseStyle.bodySize))
            let all = NSRange(location: 0, length: s.length)
            s.addAttributes([.paragraphStyle: Self.bodyStyle(first: first), .ligature: 1, Self.language: "en"], range: all)
            if base != 0 { Self.space(s, range: all, as: Fit(level: base)) }
            paragraphTexts[key] = s
            based = s
        }
        guard let t = tail, t.from < based.length else { return based }
        let s = NSMutableAttributedString(attributedString: based)
        Self.space(s, range: NSRange(location: t.from, length: s.length - t.from), as: Fit(level: t.level))
        return s
    }

    /// The character range of each line text takes in a column of `width`.
    private func lines(of s: NSAttributedString, width: CGFloat) -> [NSRange] {
        guard s.length > 0 else { return [] }
        let tl = Date()
        defer { searchStats.paraLayouts += 1; searchStats.paraMs += Date().timeIntervalSince(tl) * 1000 }
        let storage = NSTextStorage(attributedString: s)
        let lm = makeLayoutManager()
        lm.allowsNonContiguousLayout = false
        storage.addLayoutManager(lm)
        let tc = container(for: CGRect(x: 0, y: 0, width: width, height: 1e7), avoid: [], leading: HouseStyle.leading)
        lm.addTextContainer(tc)
        var out: [NSRange] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, _, _, range, _ in
            out.append(lm.characterRange(forGlyphRange: range, actualGlyphRange: nil))
        }
        return out
    }

    private func paragraphLines(_ p: String, width: CGFloat, base: Double, first: Bool) -> [NSRange] {
        let key = "\(p.hashValue)|\(width)|\(Int((base * 100).rounded()))|\(first)"
        if let l = paragraphLayouts[key] { return l }
        let l = lines(of: paragraphText(p, base: base, tail: nil, first: first), width: width)
        paragraphLayouts[key] = l
        return l
    }

    private func tailLineCount(_ p: String, width: CGFloat, base: Double, tail: Tail, first: Bool) -> Int {
        let key = "\(p.hashValue)|\(width)|\(Int((base * 100).rounded()))|\(tail.from)|\(Int((tail.level * 100).rounded()))|\(first)"
        if let n = tailLines[key] { return n }
        var n: Int
        let base0 = paragraphLines(p, width: width, base: base, first: first)
        if tail.from == 0, tail.level != 0 {
            // the whole paragraph at one setting reads the same whatever the story's own setting was, so it's shared
            // between the uniform levels the search tries (a level of 0 differs: it carries an explicit zero kern)
            n = paragraphLines(p, width: width, base: tail.level, first: first).count
        } else if tail.from > 0, let k = base0.firstIndex(where: { $0.location == tail.from }) {
            // TextKit breaks a paragraph one line at a time, each line from where the last one ended, so setting the
            // end of a paragraph differently can't move any break before it: the lines up to `from` stand, and only
            // the run from there needs setting, as the rest of a paragraph (no first-line indent)
            // the run from `from` set at the tail's level reads the same whatever the paragraph's base was
            let restKey = "\(p.hashValue)|\(width)|rest|\(tail.from)|\(Int((tail.level * 100).rounded()))"
            if tail.level != 0, let r = tailLines[restKey] {
                n = k + r
            } else {
                let full = paragraphText(p, base: base, tail: tail, first: first)
                let rest = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: tail.from, length: full.length - tail.from)))
                rest.addAttribute(.paragraphStyle, value: Self.continuationStyle, range: NSRange(location: 0, length: rest.length))
                let r = lines(of: rest, width: width).count
                if tail.level != 0 { tailLines[restKey] = r }
                n = k + r
            }
        } else {
            n = lines(of: paragraphText(p, base: base, tail: tail, first: first), width: width).count
        }
        tailLines[key] = n
        return n
    }

    /// The body style for text that carries on a paragraph already begun: no first-line indent.
    private static let continuationStyle: NSParagraphStyle = {
        let p = bodyStyle().mutableCopy() as! NSMutableParagraphStyle
        p.firstLineHeadIndent = 0
        return p
    }()

    /// Which runs of words to set tighter or looser, and how much, so the story loses or gains exactly `delta`
    /// lines on top of a uniform `base` setting, at the least cost in noticeability: strength squared times the
    /// words touched (so bigger runs moved a little win over small runs moved a lot), with a preference for the
    /// end of the story. The candidates are the last one, two or three lines
    /// of a paragraph, or all of it, each pushed only as far as it takes to move a line. Nil when no combination
    /// lands exactly.
    func localPlan(_ a: Article, delta: Int, base: Double, width: CGFloat) -> (plan: [Int: Tail], cost: Double)? {
        guard delta != 0 else { return ([:], 0) }
        let paragraphs = Self.paragraphs(of: a)
        let n = paragraphs.count
        guard n > 0 else { return nil }
        let dir: Double = delta > 0 ? 1 : -1
        let target = abs(delta)
        struct Option { var tail: Tail; var gain: Int; var cost: Double }
        var options: [[Option]] = []
        for (i, p) in paragraphs.enumerated() {
            if stopped || shouldStop?() == true { stopped = true; return nil }
            let lines = paragraphLines(p, width: width, base: base, first: i == 0)
            let position = 1 + 0.5 * Double(n - 1 - i) / Double(n)
            var best: [Int: Option] = [:]                   // the cheapest way to each gain
            let length = (p as NSString).length
            var froms: [Int] = []
            for k in [1, 2, 3] where k < lines.count { froms.append(lines[lines.count - k].location) }
            froms.append(0)
            for from in froms {
                let words = Double(max(1, length - from)) / 6        // about six characters a word
                // a run never goes past the comfortable range on its own: what the story at large can't reach
                // comfortably, it reaches with its uniform setting, not with a few conspicuous lines
                let cap = abs(base) > Fit.comfortable ? Fit.limit : Fit.comfortable
                let levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0]
                    .map { (base + dir * $0).clamped(-cap, cap) }.filter { abs($0 - base) > 0.01 }
                // every strength is tried: hyphenation means a stronger setting can now and then gain fewer lines
                for level in levels {
                    let tail = Tail(from: from, level: level)
                    let g = Int(dir) * (tailLineCount(p, width: width, base: base, tail: tail, first: i == 0) - lines.count)
                    guard g >= 1 else { continue }
                    // strength squared: moving a big run a little beats moving a small run a lot
                    let d = abs(level - base)
                    let cost = d * d * words / 8 * position * 4
                    if best[g].map({ cost < $0.cost }) ?? true { best[g] = Option(tail: tail, gain: g, cost: cost) }
                }
            }
            options.append(Array(best.values))
        }
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: target + 1), count: n + 1)
        var pick = [[Int]](repeating: [Int](repeating: -1, count: target + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0..<n {
            for g in 0...target where cost[i][g] < .infinity {
                if cost[i][g] < cost[i + 1][g] { cost[i + 1][g] = cost[i][g]; pick[i + 1][g] = -1 }
                for (k, o) in options[i].enumerated() where g + o.gain <= target {
                    let c = cost[i][g] + o.cost
                    if c < cost[i + 1][g + o.gain] { cost[i + 1][g + o.gain] = c; pick[i + 1][g + o.gain] = k }
                }
            }
        }
        guard cost[n][target] < .infinity else { return nil }
        var plan: [Int: Tail] = [:]
        var g = target
        for i in stride(from: n, to: 0, by: -1) {
            let k = pick[i][g]
            if k >= 0 { let o = options[i - 1][k]; plan[i - 1] = o.tail; g -= o.gain }
        }
        return (plan, cost[n][target])
    }

    static func headline(_ text: String, size: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size * 1.04
        p.maximumLineHeight = size * 1.04
        return NSAttributedString(string: text, attributes: [
            .font: HouseStyle.font(HouseStyle.headlineFace, size), .foregroundColor: HouseStyle.ink, .paragraphStyle: p])
    }

    /// A headline from its stored markup: *a title* inside it is set in the italic headline face.
    static func headline(markup: String, size: CGFloat) -> NSAttributedString {
        let plain = Markup.plain(markup)
        guard markup.contains("*") else { return headline(plain, size: size) }
        let marked = Markup.attributed([markup], size: 12)
        let out = NSMutableAttributedString(attributedString: headline(marked.string, size: size))
        marked.enumerateAttribute(.font, in: NSRange(location: 0, length: marked.length)) { value, range, _ in
            let name = (value as? NSFont)?.fontName.lowercased() ?? ""
            if name.hasSuffix("-it") || name.contains("boldit") || ((value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false) {
                out.addAttribute(.font, value: HouseStyle.font(HouseStyle.headlineItalicFace, size), range: range)
            }
        }
        return out
    }

    /// A field's markup set in `attrs`: its *italic* runs in the face's italic (`HouseStyle.italic`), marked with
    /// `Markup.italicKey` so the IDML export can name the real italic.
    static func marked(_ markup: String, _ attrs: [NSAttributedString.Key: Any], uppercase: Bool = false) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (text, italic) in Markup.runs(markup) {
            var a = attrs
            if italic, let f = a[.font] as? NSFont { a[.font] = HouseStyle.italic(f); a[Markup.italicKey] = true }
            out.append(NSAttributedString(string: uppercase ? text.uppercased() : text, attributes: a))
        }
        return out
    }

    /// The label over a headline, in small bold capitals.
    static func kicker(_ text: String) -> NSAttributedString {
        marked(text, [.font: HouseStyle.font(HouseStyle.kickerFace, HouseStyle.kickerSize), .foregroundColor: HouseStyle.ink, .kern: 1.2], uppercase: true)
    }

    /// The byline's names wrapped to a width, one string per line: the Times breaks a shared byline at "and".
    static func bylineLines(_ author: String, width: CGFloat) -> [String] {
        let f = HouseStyle.font("Raleway-SemiBold", 12)
        func w(_ s: String) -> CGFloat { (Markup.plain(s) as NSString).size(withAttributes: [.font: f]).width }
        let words = author.split(separator: " ").map(String.init)
        var lines: [String] = [], line = ""
        for word in words {
            let trial = line.isEmpty ? word : line + " " + word
            if w(trial) <= width || line.isEmpty { line = trial } else { lines.append(line); line = word }
        }
        if !line.isEmpty { lines.append(line) }
        return Markup.balanced(lines)                      // italics running over a line break close and reopen
    }

    /// The byline's height at a width: the house 35 pt for one line of names, a line's leading for each more.
    static func bylineHeight(_ a: Article, width: CGFloat) -> CGFloat {
        let n = bylineLines(a.author.trimmed, width: width).count
        return HouseStyle.bylineHeight + CGFloat(max(0, n - 1)) * HouseStyle.bylineLeading
    }

    /// Height of the kicker band over a headline, 0 when the story has none.
    static func kickerHeight(_ a: Article) -> CGFloat { a.kicker.trimmed.isEmpty ? 0 : HouseStyle.kickerHeight }

    static func caption(_ photo: Photo, width: CGFloat = 400) -> NSAttributedString? {
        let cap = photo.caption.trimmed, credit = photo.credit.trimmed
        guard !cap.isEmpty || !credit.isEmpty else { return nil }
        let p = NSMutableParagraphStyle()
        p.alignment = width < 300 ? .left : .justified
        p.minimumLineHeight = 10.8
        p.maximumLineHeight = 10.8
        func attrs(_ face: String) -> [NSAttributedString.Key: Any] {
            [.font: HouseStyle.font(face, 9), .foregroundColor: HouseStyle.ink, .paragraphStyle: p, language: "en"]
        }
        let s = marked(cap, attrs("MinionPro-Bold"))
        if !credit.isEmpty {
            if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: attrs("MinionPro-Regular"))) }
            if let slash = credit.firstIndex(of: "/") {
                s.append(marked(String(credit[...slash]), attrs("MinionPro-Regular")))
                s.append(marked(String(credit[credit.index(after: slash)...]), attrs("MinionPro-It")))
            } else {
                s.append(marked(credit, attrs("MinionPro-Regular")))
            }
        }
        return s
    }

    static func teaser(_ text: String, size: CGFloat, lineHeight: CGFloat = 1.21) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.hyphenationFactor = 1
        p.minimumLineHeight = size * lineHeight
        p.maximumLineHeight = size * lineHeight
        return marked(text, [.font: HouseStyle.font("UtopiaStd-BoldIt", size), .foregroundColor: HouseStyle.ink, .paragraphStyle: p, language: "en"])
    }

    static func pullQuote(_ text: String, width: CGFloat) -> NSAttributedString {
        let size: CGFloat = width >= 300 ? 20 : 17
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.minimumLineHeight = size * 1.2
        p.maximumLineHeight = size * 1.2
        return marked(text, [.font: HouseStyle.font("Raleway", size), .foregroundColor: HouseStyle.ink, .paragraphStyle: p])
    }

    func height(of s: NSAttributedString, width: CGFloat) -> CGFloat {
        // an attributed string hashes by its characters alone: the face and size go into the key by hand
        let font = s.length > 0 ? s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let key = "\(s.string.hashValue)|\(font?.fontName ?? "")|\(font?.pointSize ?? 0)|\(s.length)|\(width)"
        if let h = textHeights[key] { return h }
        let h = ceil(s.boundingRect(with: CGSize(width: width, height: 1e6), options: [.usesLineFragmentOrigin]).height)
        textHeights[key] = h
        return h
    }

    // MARK: pictures on the page

    struct InsetGeometry { var picture: CGRect; var text: NSAttributedString?; var textRect: CGRect?; var full: CGRect }

    /// A picture of `size` fitted whole inside `r`, centred; `r` itself when the size isn't known.
    static func fitted(_ size: CGSize?, in r: CGRect) -> CGRect {
        guard let s = size, s.width > 0, s.height > 0, r.width > 0, r.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        return CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
    }

    func geometry(_ inset: Inset, _ article: Article?, _ extra: Extra? = nil) -> InsetGeometry? {
        let r = inset.frame.rect
        if inset.kind == .extra {
            guard let e = extra else { return nil }
            // an ad or graphic is drawn whole, fitted inside its frame: the picture is what's drawn, so text wraps
            // around the ad itself, not the empty part of a frame of another shape
            let pic = Self.fitted(image(e.path)?.size, in: r)
            guard let c = Self.caption(Photo(path: e.path, caption: e.caption, credit: e.credit), width: pic.width) else {
                return InsetGeometry(picture: pic, text: nil, textRect: nil, full: pic)
            }
            let cr = CGRect(x: pic.minX, y: pic.maxY + 4, width: pic.width, height: height(of: c, width: pic.width))
            return InsetGeometry(picture: pic, text: c, textRect: cr, full: pic.union(cr))
        }
        guard let a = article else { return nil }
        switch inset.kind {
        case .photo:
            guard let p = a.photos.first(where: { $0.id == inset.photo }) else { return nil }
            guard let c = Self.caption(p, width: r.width) else { return InsetGeometry(picture: r, text: nil, textRect: nil, full: r) }
            let cr = CGRect(x: r.minX, y: r.maxY + 4, width: r.width, height: height(of: c, width: r.width))
            return InsetGeometry(picture: r, text: c, textRect: cr, full: r.union(cr))
        case .pullQuote:
            let q = a.pullQuote.trimmed
            guard !q.isEmpty else { return nil }
            let t = Self.pullQuote(q, width: r.width)
            let pad: CGFloat = 10
            let box = CGRect(x: r.minX, y: r.minY, width: r.width, height: height(of: t, width: r.width - 2 * pad) + 2 * pad)
            return InsetGeometry(picture: box, text: t, textRect: box.insetBy(dx: pad, dy: pad), full: box)
        case .extra:
            return nil
        }
    }

    /// What display type keeps between itself and a picture, in points.
    static let displayClearance: CGFloat = 4

    /// The area a story keeps clear of around another story's block lying on top of it.
    static func wrapBlock(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX - HouseStyle.gutter, y: f.minY - 10, width: f.width + 2 * HouseStyle.gutter, height: f.height + 10 + HouseStyle.moduleGap - 6)
    }

    static let clearAbovePicture: CGFloat = 8
    static let clearBelowPicture: CGFloat = 4             // under the caption: the text comes up close, a line nearer than it was at 10

    /// A picture's frame put on a story's line grid. The top goes where a line ends plus the clearance above a
    /// picture, so the line over it is always the same distance away; the height is trimmed by less than a line
    /// (the picture is cropped to fill, so nothing is lost) so that the text under its caption starts exactly on a
    /// line, the clearance below. With `anchorBottom` the bottom edge stays and the top moves instead.
    static func onLineGrid(_ r: CGRect, caption: CGFloat, bodyTop: CGFloat, pitch: CGFloat, anchorBottom: Bool = false) -> CGRect {
        guard pitch > 0, r.height > 0 else { return r }
        func line(_ y: CGFloat) -> CGFloat { bodyTop + ((y - bodyTop) / pitch).rounded() * pitch }
        if anchorBottom {
            // the text below starts on the line after caption and clearance: the bottom is that line less both
            let below = line(r.maxY + caption + clearBelowPicture)
            let bottom = below - caption - clearBelowPicture
            let top = line(r.minY - clearAbovePicture) + clearAbovePicture
            return CGRect(x: r.minX, y: top, width: r.width, height: max(40, bottom - top))
        }
        let top = line(r.minY - clearAbovePicture) + clearAbovePicture
        let below = line(top + r.height + caption + clearBelowPicture)
        let height = below - caption - clearBelowPicture - top
        return CGRect(x: r.minX, y: top, width: r.width, height: max(40, height))
    }

    /// The area body text keeps clear of around a picture and its caption.
    static func wrap(_ full: CGRect) -> CGRect {
        CGRect(x: full.minX - HouseStyle.gutter, y: full.minY - clearAbovePicture, width: full.width + 2 * HouseStyle.gutter, height: full.height + clearAbovePicture + clearBelowPicture)
    }

    // MARK: story modules

    /// Height of a headline set across `width` with nothing in its way.
    /// The display type over the body: the kicker band (if any) and the headline, at a width.
    func headlineHeight(_ a: Article, width: CGFloat, size: CGFloat) -> CGFloat {
        let text = a.headline.trimmed
        guard !a.plainHeadline.trimmed.isEmpty else { return Self.kickerHeight(a) }
        let key = "\(text)|\(width)|\(size)"
        if let h = headlineHeights[key] { return h + Self.kickerHeight(a) }
        let frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        let h = setHeadline(text, frame: frame, size: size, avoid: [])?.used ?? 0
        headlineHeights[key] = h
        return h + Self.kickerHeight(a)
    }

    private func setHeadline(_ markup: String, frame: CGRect, size: CGFloat, avoid: [CGRect])
        -> (storage: NSTextStorage, manager: NSLayoutManager, container: FlowContainer, used: CGFloat)? {
        guard !Markup.plain(markup).trimmed.isEmpty else { return nil }
        return setHeadline(Self.headline(markup: markup, size: size), frame: frame, avoid: avoid)
    }

    /// A headline set in a frame as a block sets it (a headline frame of a component draws the same lines).
    func setHeadline(_ text: NSAttributedString, frame: CGRect, avoid: [CGRect])
        -> (storage: NSTextStorage, manager: NSLayoutManager, container: FlowContainer, used: CGFloat)? {
        guard text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let lm = makeLayoutManager()
        storage.addLayoutManager(lm)
        let tc = FlowContainer(size: CGSize(width: frame.width, height: max(frame.height, 1)))
        tc.lineFragmentPadding = 0
        tc.minimumFraction = 0.3
        tc.slack = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.leading ?? 0
        tc.obstacles = avoid.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return (storage, lm, tc, ceil(lm.usedRect(for: tc).maxY))
    }

    /// Lay out the furniture of a story module: headline, byline, columns, jump line.
    /// With `draw` false the headline is only set when something is in its way.
    func blockGeometry(_ a: Article, frame: CGRect, columns: Int, headlineSize: CGFloat, avoid obstacles: [CGRect],
                       bylineColumns: Int = 1, bodyTop atLeast: CGFloat? = nil, draw: Bool = true,
                       gutter: CGFloat = HouseStyle.gutter, bodyOnly: Bool = false) -> BlockGeometry {
        let colW = (frame.width - CGFloat(columns - 1) * gutter) / CGFloat(columns)
        func colX(_ i: Int) -> CGFloat { frame.minX + CGFloat(i) * (colW + gutter) }
        var avoid = obstacles.filter { $0.intersects(frame) }
        // obstacles come padded for body text (wrap: 8 pt above a picture, 4 below its caption). Display type keeps only a
        // few points clear, so a headline wraps when a picture is really in its way, not when one sits a line below
        let display = avoid.map {
            CGRect(x: $0.minX, y: $0.minY + 8 - Self.displayClearance, width: $0.width,
                   height: max(1, $0.height - (Self.clearAbovePicture - Self.displayClearance) - (Self.clearBelowPicture - Self.displayClearance)))
        }

        // a body frame in a component carries the body alone: no kicker, headline or byline
        let kick = bodyOnly ? 0 : Self.kickerHeight(a)
        let kicker = kick > 0 ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: kick) : nil
        let headFrame = CGRect(x: frame.minX, y: frame.minY + kick, width: frame.width, height: max(1, frame.height - kick))
        let clear = bodyOnly ? 0 : headlineHeight(a, width: frame.width, size: headlineSize) - kick
        let band = CGRect(x: frame.minX, y: headFrame.minY, width: frame.width, height: clear)
        let inTheWay = display.contains(where: { $0.intersects(band) })
        // a picture in the headline's way: the headline may be set smaller rather than squeezed beside it
        let size = !bodyOnly && inTheWay ? fittedHeadlineSize(a.headline.trimmed, frame: headFrame, size: headlineSize, avoid: display) : headlineSize
        let head = !bodyOnly && (draw || inTheWay)
            ? setHeadline(a.headline.trimmed, frame: headFrame, size: size, avoid: display) : nil
        let used = head?.used ?? clear
        let natural = headFrame.minY + used + (used > 0 || kick > 0 ? HouseStyle.headlineGap : 0)
        // stories set side by side start their bylines on one line (`atLeast`). The tops stay level too: the
        // kicker or headline of each starts at the block's top, so the top things line up across the page, and the
        // shorter headline's extra air goes between it and its byline
        let extra = max(0, (atLeast ?? 0) - natural)
        let bodyTop = natural + extra

        var byline: CGRect?
        if !bodyOnly, !a.author.trimmed.isEmpty {
            let n = max(1, min(columns, bylineColumns))
            let bw = colW * CGFloat(n) + gutter * CGFloat(n - 1)
            let h = Self.bylineHeight(a, width: bw)
            var y = bodyTop
            while let hit = avoid.first(where: { $0.minY < y + h && $0.maxY > y && $0.minX < colX(0) + bw && $0.maxX > colX(0) }) {
                y = hit.maxY + 1
            }
            if y + h <= frame.maxY {
                byline = CGRect(x: colX(0), y: y, width: bw, height: h)
                avoid.append(CGRect(x: colX(0), y: y, width: bw, height: h + 4))
            }
        }
        // the jump line goes at the foot of the last column the text reaches the bottom of: the rightmost column
        // whose foot nothing covers (a picture or graphic over the last columns' feet sends it left, under the text)
        func jumpRect(_ i: Int) -> CGRect { CGRect(x: colX(i), y: frame.maxY - HouseStyle.leading - 3, width: colW, height: HouseStyle.leading + 3) }
        let jump = (0..<columns).reversed().map(jumpRect).first { r in !avoid.contains { $0.intersects(r) } } ?? jumpRect(columns - 1)
        let cols = (0..<columns).map { CGRect(x: colX($0), y: bodyTop, width: colW, height: max(0, frame.maxY - bodyTop)) }
        return BlockGeometry(headline: head.map { ($0.storage, $0.manager, $0.container) }, bodyTop: bodyTop,
                             columns: cols, avoid: avoid, byline: byline, kicker: kicker, headTop: frame.minY, jump: jump,
                             headlineSize: size)
    }

    private var fittedHeadlineSizes: [String: CGFloat] = [:]

    /// The size to set a headline at when a picture is in its way. Squeezed beside a picture, a headline can end
    /// up a word to a line in a narrow strip with empty space around it ("reimagining / HASS" beside a photo), so
    /// sizes down to 3/4 of the block's are tried, each costed: a line squeezed beside a picture costs 1, the
    /// empty space beside such lines up to 1 more per line's worth, and shrinking 6 per whole size lost (so about
    /// a sixth smaller is worth one squeezed line). The largest size of the lowest cost wins.
    func fittedHeadlineSize(_ markup: String, frame: CGRect, size: CGFloat, avoid: [CGRect]) -> CGFloat {
        let key = "\(markup)|\(frame)|\(size)|\(avoid)"
        if let s = fittedHeadlineSizes[key] { return s }
        func cost(_ s: CGFloat) -> Double? {
            guard let h = setHeadline(markup, frame: frame, size: s, avoid: avoid) else { return nil }
            var squeezed = 0, empty: CGFloat = 0, lineHeight: CGFloat = 1
            h.manager.enumerateLineFragments(forGlyphRange: h.manager.glyphRange(for: h.container)) { rect, used, _, _, _ in
                lineHeight = max(lineHeight, rect.height)
                guard rect.width < frame.width - 0.5 else { return }
                squeezed += 1
                empty += max(0, rect.width - used.width) * rect.height
            }
            return Double(squeezed) + Double(empty / (frame.width * lineHeight)) + 6 * Double(1 - s / size)
        }
        var best = size, bestCost = cost(size) ?? 0
        var s = size - 1
        while bestCost > 0.001, s >= max(size * 0.75, 14) {
            if let c = cost(s), c < bestCost - 0.001 { best = s; bestCost = c }
            s -= 1
        }
        fittedHeadlineSizes[key] = best
        return best
    }

    /// Where the body (and byline) starts in each block of a page once stories set side by side are lined up: blocks
    /// whose tops sit on one line share the lowest of their natural starts, so their bylines and first lines align
    /// across the page, as the Times keeps them. A difference too big to be a headline's line or two is left alone.
    func alignedBodyTops(_ page: PageLayout, articles: [Article.ID: Article], _ obs: Obstacles) -> [StoryBlock.ID: CGFloat] {
        var natural: [StoryBlock.ID: CGFloat] = [:]
        for b in page.stories {
            guard let a = articles[b.article] else { continue }
            natural[b.id] = blockGeometry(a, frame: b.frame.rect, columns: b.columns, headlineSize: b.headlineSize,
                                          avoid: avoid(for: b, on: page, obs), bylineColumns: b.bylineColumns, draw: false).bodyTop
        }
        var out: [StoryBlock.ID: CGFloat] = [:]
        let blocks = page.stories.filter { natural[$0.id] != nil }
        for b in blocks {
            let row = blocks.filter { abs($0.frame.y - b.frame.y) <= 6 && $0.article != b.article || $0.id == b.id }
            // a story set in a component's frames sits in the row too, its body top fixed where its frame starts
            let heads = obs.storyHeads.filter { abs($0.top - b.frame.y) <= 6 && $0.article != b.article }.map(\.bodyTop)
            guard row.count + heads.count > 1, let lowest = (row.compactMap({ natural[$0.id] }) + heads).max(), let mine = natural[b.id] else { continue }
            if lowest - mine > 0.5, lowest - mine <= 60 { out[b.id] = lowest }
        }
        return out
    }

    /// The hairlines between stories that sit against each other. One rule runs under a row of stories, across the
    /// whole of the story below it, placed by the ink either side (the last line above, the capitals below) rather
    /// than by the frames, nearer the story it closes, and at one height along the row, so it is one line, not
    /// pieces at different heights. One rule runs down a gutter between stories set side by side, from the
    /// capitals of the taller headline to the last line set. Nothing is drawn where a picture or ad already marks
    /// the edge, or where the ink would leave a rule no room.
    static func storyRules(_ page: PageLayout, results: [StoryBlock.ID: BlockResult] = [:], around art: [CGRect]) -> [(from: CGPoint, to: CGPoint)] {
        var out: [(from: CGPoint, to: CGPoint)] = []
        let blocks = page.stories
        func inkTop(_ b: StoryBlock) -> CGFloat { results[b.id].map { $0.inkTop > 0 ? $0.inkTop : b.frame.rect.minY } ?? b.frame.rect.minY }
        func inkBottom(_ b: StoryBlock) -> CGFloat {
            results[b.id].map { $0.inkBottom > 0 ? min($0.inkBottom, b.frame.rect.maxY) : b.frame.rect.maxY } ?? b.frame.rect.maxY
        }
        let minimumAir: CGFloat = 8                       // ink to rule, either side, at the least

        // across: for each story, the stories whose frames end just above it
        var across: [(y: CGFloat, x0: CGFloat, x1: CGFloat, row: CGFloat)] = []
        for b in blocks {
            let f = b.frame.rect
            let uppers = blocks.filter { u in
                u.article != b.article && f.minY - u.frame.rect.maxY >= -1 && f.minY - u.frame.rect.maxY <= HouseStyle.moduleGap * 2.5
                    && min(f.maxX, u.frame.rect.maxX) - max(f.minX, u.frame.rect.minX) > 40
            }
            guard !uppers.isEmpty, let lowest = uppers.map(inkBottom).max() else { continue }
            let air = inkTop(b) - lowest
            guard air >= 2 * minimumAir else { continue }
            let x0 = max(f.minX, uppers.map(\.frame.rect.minX).min()!), x1 = min(f.maxX, uppers.map(\.frame.rect.maxX).max()!)
            // the rule keeps to the story it closes: a third of the air above it, two thirds under it, so a
            // headline has more room over it than under it and reads as the start of what follows (the Times
            // runs about 7 pt from its text to the rule and 12 to the capitals below)
            across.append((y: lowest + air / 3, x0: x0, x1: x1, row: f.minY))
        }
        // stories whose tops share a line share one rule height, so the line runs straight across the page
        for i in across.indices {
            let rowmates = across.filter { abs($0.row - across[i].row) <= 6 }
            across[i].y = (rowmates.map(\.y).min()! ).rounded()
        }
        // pieces at one height that meet across a gutter are one line
        var joined: [(y: CGFloat, x0: CGFloat, x1: CGFloat)] = []
        for r in across.sorted(by: { $0.y == $1.y ? $0.x0 < $1.x0 : $0.y < $1.y }) {
            if let k = joined.indices.last, joined[k].y == r.y, r.x0 - joined[k].x1 <= HouseStyle.gutter + 1 {
                joined[k].x1 = max(joined[k].x1, r.x1)
            } else { joined.append((r.y, r.x0, r.x1)) }
        }
        for r in joined {
            let seg = CGRect(x: r.x0, y: r.y - 1, width: r.x1 - r.x0, height: 2)
            if !art.contains(where: { $0.intersects(seg) }) { out.append((CGPoint(x: r.x0, y: r.y), CGPoint(x: r.x1, y: r.y))) }
        }

        // down: between stories side by side, centred in the gutter
        for i in blocks.indices {
            for j in blocks.indices where i != j {
                let a = blocks[i].frame.rect, b = blocks[j].frame.rect
                guard blocks[i].article != blocks[j].article else { continue }
                let dx = b.minX - a.maxX
                let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
                guard dx >= 4, dx <= HouseStyle.gutter * 2, y1 - y0 > 60 else { continue }
                let x = ((a.maxX + b.minX) / 2 * 2).rounded() / 2
                let top = max(y0, min(inkTop(blocks[i]), inkTop(blocks[j])))
                let bottom = min(y1, max(inkBottom(blocks[i]), inkBottom(blocks[j])))
                guard bottom - top > 60 else { continue }
                let seg = CGRect(x: x - 1, y: top, width: 2, height: bottom - top)
                if !art.contains(where: { $0.intersects(seg) }) { out.append((CGPoint(x: x, y: top), CGPoint(x: x, y: bottom))) }
            }
        }
        // the same gutter rule from two pairs is one rule
        var merged: [(from: CGPoint, to: CGPoint)] = []
        for r in out {
            if r.from.x == r.to.x, let k = merged.firstIndex(where: { $0.from.x == $0.to.x && $0.from.x == r.from.x && $0.to.y >= r.from.y - 1 && $0.from.y <= r.to.y + 1 }) {
                merged[k] = (CGPoint(x: r.from.x, y: min(merged[k].from.y, r.from.y)), CGPoint(x: r.from.x, y: max(merged[k].to.y, r.to.y)))
            } else { merged.append(r) }
        }
        return merged
    }

    private func container(for col: CGRect, avoid: [CGRect], leading: CGFloat = HouseStyle.leading) -> FlowContainer {
        let tc = FlowContainer(size: col.size)
        tc.lineFragmentPadding = 0
        tc.pitch = leading
        tc.obstacles = avoid.map { $0.offsetBy(dx: -col.minX, dy: -col.minY) }
        return tc
    }

    /// Body lines a module holds, column by column, without setting any text.
    func capacity(_ g: BlockGeometry, jump: Bool, leading: CGFloat = HouseStyle.leading) -> [Int] {
        let avoid = jump ? g.avoid + [g.jump] : g.avoid
        return g.columns.map { container(for: $0, avoid: avoid, leading: leading).lineCapacity(height: leading).count }
    }

    /// The text a block sets: optionally "Continued from Page N." then the body from `start`.
    private func blockText(_ a: Article, start: Int, continuedFrom: Int?, fit: Fit = .neutral) -> (text: NSAttributedString, prefix: Int, start: Int, total: Int) {
        let full = body(a, fit: fit)
        let ns = full.string as NSString
        var s = max(0, min(start, full.length))
        while s < ns.length, let u = UnicodeScalar(ns.character(at: s)), CharacterSet.whitespacesAndNewlines.contains(u) { s += 1 }
        let text = NSMutableAttributedString()
        if let from = continuedFrom, s < full.length {
            text.append(NSAttributedString(string: "Continued from Page \(from). ", attributes: Self.continuedAttributes(fit)))
        }
        let prefix = text.length
        if s < full.length { text.append(full.attributedSubstring(from: NSRange(location: s, length: full.length - s))) }
        return (text, prefix, s, full.length)
    }

    /// Lines a story's remaining text needs in one column of `width`.
    func lineCount(_ a: Article, start: Int, continuedFrom: Int?, width: CGFloat, fit: Fit = .neutral) -> Int {
        let key = "\(a.id)|\(a.body.hashValue)|\(start)|\(continuedFrom ?? 0)|\(width)|\(fit.key)"
        if let n = lineCounts[key] { return n }
        let t = blockText(a, start: start, continuedFrom: continuedFrom, fit: fit)
        guard t.text.length > 0 else { lineCounts[key] = 0; return 0 }
        let storage = NSTextStorage(attributedString: t.text)
        let lm = makeLayoutManager()
        storage.addLayoutManager(lm)
        let tc = container(for: CGRect(x: 0, y: 0, width: width, height: 1e7), avoid: [], leading: fit.leading)
        lm.addTextContainer(tc)
        var n = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, _, _, _, _ in n += 1 }
        lineCounts[key] = n
        return n
    }

    /// Set one story module. With `page` nil it only measures.
    @discardableResult
    func setBlock(_ a: Article, frame: CGRect, columns: Int, headlineSize: CGFloat, start: Int,
                  continuedFrom: Int?, jumpTo: Int?, avoid obstacles: [CGRect], fit: Fit = .neutral,
                  bylineColumns: Int = 1, bodyTop: CGFloat? = nil, geometry: BlockGeometry? = nil,
                  gutter: CGFloat = HouseStyle.gutter, bodyOnly: Bool = false, into page: ComposedPage?) -> BlockResult {
        let g = geometry ?? blockGeometry(a, frame: frame, columns: columns, headlineSize: headlineSize, avoid: obstacles,
                                          bylineColumns: bylineColumns, bodyTop: bodyTop, draw: page != nil, gutter: gutter, bodyOnly: bodyOnly)
        if let page {
            if let k = g.kicker {
                let t = Self.kicker(a.kicker.trimmed)
                let w = ceil(t.size().width) + 2
                let f = HouseStyle.font(HouseStyle.kickerFace, HouseStyle.kickerSize)
                page.ops.append(.text(t, CGRect(x: k.minX, y: k.minY + 9.5 - f.ascender, width: min(w, k.width), height: ceil(f.ascender - f.descender) + 2)))
            }
            if let h = g.headline {
                page.ops.append(.flow(h.manager, h.container, CGPoint(x: frame.minX, y: g.headTop + (g.kicker?.height ?? 0))))
                page.keep.append(h.storage)
            }
            if let b = g.byline { drawByline(a, in: b, into: page) }
        }

        let t = blockText(a, start: start, continuedFrom: continuedFrom, fit: fit)
        struct Set { var lm: NSLayoutManager; var storage: NSTextStorage; var bottom: CGFloat; var used: Int; var room: Int; var end: Int }
        func set(reserveJump: Bool) -> Set {
            let storage = NSTextStorage(attributedString: t.text)
            let lm = makeLayoutManager()
            lm.allowsNonContiguousLayout = false
            storage.addLayoutManager(lm)
            let avoid = reserveJump ? g.avoid + [g.jump] : g.avoid
            for col in g.columns { lm.addTextContainer(container(for: col, avoid: avoid, leading: fit.leading)) }
            var glyphEnd = 0
            var bottom = g.bodyTop
            var used = 0
            for (tc, col) in zip(lm.textContainers, g.columns) {
                let range = lm.glyphRange(for: tc)
                guard range.length > 0 else { continue }
                glyphEnd = NSMaxRange(range)
                bottom = max(bottom, col.minY + lm.usedRect(for: tc).maxY)
                lm.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, _ in used += 1 }
            }
            let room = lm.textContainers.reduce(0) { $0 + (($1 as? FlowContainer)?.lineCapacity(height: fit.leading).count ?? 0) }
            let charEnd = glyphEnd < lm.numberOfGlyphs ? lm.characterIndexForGlyph(at: glyphEnd) : storage.length
            var end = min(t.total, t.start + max(0, charEnd - t.prefix))
            if end < t.total {
                // a word hyphenated at the foot of the block is set whole where the story continues
                end = Self.wordStart(body(a).string as NSString, at: end, floor: t.start)
            } else {
                end = t.total
            }
            return Set(lm: lm, storage: storage, bottom: bottom, used: used, room: room, end: end)
        }
        // the jump line's slot is only given up when the story really runs on: a story that ends here keeps
        // its last line, so the last column comes out as full as the others
        var s = set(reserveJump: false)
        if s.end < t.total { s = set(reserveJump: true) }      // it runs on, to another page or to the website
        if let page {
            for (tc, col) in zip(s.lm.textContainers, g.columns) where s.lm.glyphRange(for: tc).length > 0 {
                page.ops.append(.flow(s.lm, tc, col.origin))
            }
            page.keep.append(s.storage)
        }
        // where this block's lines broke inside a word: the exporter hands InDesign these hyphenation points and no others
        var hyphens: [Int] = []
        if page != nil {
            let str = s.storage.string as NSString
            func letter(_ k: Int) -> Bool {
                guard k >= 0, k < str.length, let u = UnicodeScalar(str.character(at: k)) else { return false }
                return CharacterSet.letters.contains(u)
            }
            for tc in s.lm.textContainers {
                let range = s.lm.glyphRange(for: tc)
                guard range.length > 0 else { continue }
                s.lm.enumerateLineFragments(forGlyphRange: range) { rect, usedRect, _, g, _ in
                    let c = s.lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                    let e = NSMaxRange(c)
                    let hyphenated = e > t.prefix && letter(e - 1) && letter(e)
                    if hyphenated { hyphens.append(t.start + e - t.prefix) }
                    if let log = Self.lineLog {
                        let indent = (c.location == 0 || str.character(at: c.location - 1) == 0x0A)
                            && !(t.start == 0 && c.location == 0)                // a story's first paragraph is flush
                        let line = str.substring(with: c).replacingOccurrences(of: "\n", with: "")
                        log.write("\(a.id)\t\(rect.width)\t\(indent ? 1 : 0)\t\(hyphenated ? 1 : 0)\t\(usedRect.width)\t\(line)\n".data(using: .utf8)!)
                    }
                }
            }
        }
        let bottom = s.bottom, used = s.used, room = s.room, end = s.end
        let jumped = end < t.total && jumpTo != nil
        let online = end < t.total && jumpTo == nil             // the story's last block, and it isn't finished
        var overset = 0
        if online { overset = lineCount(a, start: end, continuedFrom: nil, width: g.columns[0].width, fit: fit) }
        if let page, end < t.total {
            let p = NSMutableParagraphStyle(); p.alignment = .right
            let line = jumped ? "See \(a.jumpWord), Page \(jumpTo!)." : HouseStyle.onlineLine
            let s = NSAttributedString(string: line, attributes: [
                .font: HouseStyle.font("Raleway-Bold", 12), .foregroundColor: HouseStyle.ink, .paragraphStyle: p])
            let f = HouseStyle.font("Raleway-Bold", 12)
            page.ops.append(.text(s, CGRect(x: g.jump.minX, y: g.jump.maxY - 2 - f.ascender, width: g.jump.width, height: 20)))
            if online { page.online.append(.init(at: CGPoint(x: g.columns.last!.maxX, y: frame.maxY), lines: overset, story: a.plainHeadline)) }
        }
        var inkTop = g.bodyTop + 3
        if g.kicker != nil {
            inkTop = g.headTop + 9.5 - HouseStyle.font(HouseStyle.kickerFace, HouseStyle.kickerSize).capHeight
        } else if let h = g.headline, h.storage.length > 0 {
            let frag = h.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let base = frag.minY + h.manager.location(forGlyphAt: 0).y
            let font = (h.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? HouseStyle.font(HouseStyle.headlineFace, headlineSize)
            inkTop = g.headTop + (g.kicker?.height ?? 0) + base - font.capHeight
        } else if let b = g.byline {
            inkTop = b.minY
        }
        let inkBottom = max(g.bodyTop, used > 0 ? bottom : (g.byline?.maxY ?? g.bodyTop))
        return BlockResult(start: t.start, end: end, total: t.total, bottom: bottom, jumped: jumped,
                           used: used, room: room, oversetLines: overset, online: online, hyphens: hyphens, continuedFrom: continuedFrom, jumpTo: jumpTo,
                           byline: g.byline, inkTop: inkTop, inkBottom: inkBottom)
    }

    static func wordStart(_ s: NSString, at i: Int, floor: Int) -> Int {
        func wordChar(_ k: Int) -> Bool {
            guard k >= 0, k < s.length, let u = UnicodeScalar(s.character(at: k)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "’" || u == "'"
        }
        guard wordChar(i), wordChar(i - 1) else { return i }
        var j = i
        while j > floor, wordChar(j - 1) { j -= 1 }
        return j
    }

    private func drawByline(_ a: Article, in r: CGRect, into page: ComposedPage) {
        page.ops.append(.line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), 0.5, HouseStyle.ink))
        let lines = Self.bylineLines(a.author.trimmed, width: r.width)
        var baseline = r.minY + 14.8
        for line in lines {
            page.ops.append(Self.label(line, face: "Raleway-SemiBold", size: 12, color: HouseStyle.bylineRed, .left(r.minX), baseline: baseline, width: r.width))
            baseline += HouseStyle.bylineLeading
        }
        if !a.authorTitle.trimmed.isEmpty {
            page.ops.append(Self.label(a.authorTitle.trimmed, face: "MyriadPro-It", size: 10, .left(r.minX), baseline: baseline, width: r.width))
        }
        page.ops.append(.line(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), 0.5, HouseStyle.ink))
    }

    enum Align { case left(CGFloat), center(CGFloat), right(CGFloat) }

    /// One line of type positioned by its baseline.
    static func label(_ text: String, face: String, size: CGFloat, color: NSColor = HouseStyle.ink,
                      _ align: Align, baseline: CGFloat, width maxWidth: CGFloat? = nil) -> DrawOp {
        let f = HouseStyle.font(face, size)
        let s = marked(text, [.font: f, .foregroundColor: color])
        let w = min(ceil(s.size().width) + 1, maxWidth ?? .greatestFiniteMagnitude)
        let x: CGFloat
        switch align {
        case .left(let l): x = l
        case .center(let c): x = c - w / 2
        case .right(let r): x = r - w
        }
        return .text(s, CGRect(x: x, y: baseline - f.ascender, width: w, height: ceil(f.ascender - f.descender) + 2))
    }

    // MARK: the issue

    struct Obstacles {
        var geoms: [Inset.ID: InsetGeometry]
        var wrap: [CGRect]                                   // pictures, pull quotes, ads and placed components, padded
        var components: [PlacedComponent.ID: CGRect] = [:]   // each placed component's padded frame, also in `wrap`
        var pictures: [CGRect] = []                          // `wrap` without the components
        var componentOrder: [PlacedComponent.ID] = []        // bottom to top, as drawn
        /// Components whose frames set a story (phase 7): a block keeps clear of one only where it overlaps it, as
        /// of a block lying on it; its pictures are in `wrap` as pictures. And their stories' heads, for lining up
        /// a neighbour's byline (`alignedBodyTops`).
        var storyComponents: [CGRect] = []
        var storyHeads: [StoryHead] = []
    }

    func obstacles(_ page: PageLayout, articles: [Article.ID: Article]) -> Obstacles {
        var geoms: [Inset.ID: InsetGeometry] = [:]
        var wrap: [CGRect] = []
        for inset in page.insets {
            guard let g = geometry(inset, inset.article.flatMap { articles[$0] }, inset.extra.flatMap { extras[$0] }) else { continue }
            geoms[inset.id] = g
            wrap.append(Self.wrap(g.full))
        }
        let pictures = wrap
        var components: [PlacedComponent.ID: CGRect] = [:]
        var storyComponents: [CGRect] = [], heads: [StoryHead] = []
        for p in page.components {                           // a placed component is an obstacle like a picture
            let w = Self.wrap(p.frame.rect)
            components[p.id] = w
            if let s = storyShape(p, articles: articles) {   // ...unless it sets a story: then as a block, and its pictures
                wrap += s.pictures
                storyComponents.append(p.frame.rect)
                heads += s.heads
            } else {
                wrap.append(w)
            }
        }
        return Obstacles(geoms: geoms, wrap: wrap, components: components, pictures: pictures, componentOrder: page.components.map(\.id),
                         storyComponents: storyComponents, storyHeads: heads)
    }

    /// What a block must keep clear of: pictures, and blocks lying on top of it.
    func avoid(for b: StoryBlock, on page: PageLayout, _ obs: Obstacles) -> [CGRect] {
        let z = page.stories.firstIndex { $0.id == b.id } ?? 0
        let above = page.stories.dropFirst(z + 1).map(\.frame.rect).filter { $0.intersects(b.frame.rect) }.map(Self.wrapBlock)
        return obs.wrap + above + obs.storyComponents.filter { $0.intersects(b.frame.rect) }.map(Self.wrapBlock)
    }

    typealias StoryBlockSpec = (frame: CGRect, columns: Int, headlineSize: CGFloat, avoid: [CGRect], continuedFrom: Int?, jumpTo: Int?, bylineColumns: Int, bodyTop: CGFloat?,
                                gutter: CGFloat, bodyOnly: Bool)

    /// A jump carrying fewer lines than this (about two inches of a column) is a sliver.
    static let minimumJump = 10

    struct Measure { var overset = 0, used = 0, room = 0; var perBlock: [(used: Int, room: Int)] = [] }

    /// Sets a story into its blocks at a given fit, without drawing, and reports what happened.
    /// Where compose time goes, for the profiler: counts and milliseconds since the last reset.
    struct Stats { var measures = 0, measureMs = 0.0, fits = 0, fitMs = 0.0, pages = 0, pageMs = 0.0, composeMs = 0.0, composes = 0 }
    static var stats = Stats()

    /// Layout managers made so they can be used off the main thread: background fitting runs composers side by side.
    /// TextKit's own background layout runs on the main thread, so it's off (it would reach into a layout manager
    /// a fitting thread is using); and each composer has its own typesetter and glyph generator, since by default
    /// every layout manager shares one of each, and they aren't safe on two threads at once.
    private let typesetter = NSATSTypesetter()
    private let glyphs = NSGlyphGenerator()
    private func makeLayoutManager() -> NSLayoutManager {
        let lm = NSLayoutManager()
        lm.backgroundLayoutEnabled = false
        lm.typesetter = typesetter
        lm.glyphGenerator = glyphs
        return lm
    }

    /// Asked between steps of a fit search on a background lane: true once a newer state has replaced the one being
    /// fitted, so the search stops at once instead of finishing work nobody will see.
    var shouldStop: (() -> Bool)?
    /// What one fit search did, for the profiler: measures and their time, paragraph layouts made, local plans.
    var searchStats = (measures: 0, measureMs: 0.0, paraLayouts: 0, paraMs: 0.0, plans: 0, planMs: 0.0)
    /// Set when a search stopped early; its result is to be thrown away.
    var stopped = false

    private func measurer(_ a: Article, blocks: [StoryBlockSpec]) -> (Fit) -> Measure {
        let geoms = blocks.map { blockGeometry(a, frame: $0.frame, columns: $0.columns, headlineSize: $0.headlineSize, avoid: $0.avoid, bylineColumns: $0.bylineColumns, bodyTop: $0.bodyTop, draw: false, gutter: $0.gutter, bodyOnly: $0.bodyOnly) }
        return { fit in
            if self.stopped || self.shouldStop?() == true {
                self.stopped = true
                return Measure(overset: 1, perBlock: blocks.map { _ in (0, 0) })        // anything; the result is discarded
            }
            let ts = Date()
            defer { self.searchStats.measures += 1; self.searchStats.measureMs += Date().timeIntervalSince(ts) * 1000 }
            let t0 = Date()
            defer { if Thread.isMainThread { Self.stats.measures += 1; Self.stats.measureMs += Date().timeIntervalSince(t0) * 1000 } }
            var m = Measure()
            var cursor = 0
            for (b, g) in zip(blocks, geoms) {
                let r = self.setBlock(a, frame: b.frame, columns: b.columns, headlineSize: b.headlineSize, start: cursor,
                                      continuedFrom: b.continuedFrom, jumpTo: b.jumpTo, avoid: b.avoid, fit: fit, bylineColumns: b.bylineColumns, bodyTop: b.bodyTop, geometry: g,
                                      gutter: b.gutter, bodyOnly: b.bodyOnly, into: nil)
                cursor = r.end; m.used += r.used; m.room += r.room; m.overset = r.oversetLines
                m.perBlock.append((r.used, r.room))
            }
            return m
        }
    }

    /// How a story is set to fill the blocks it has.
    /// First, every column ends on the same line: the story must come to exactly the lines its blocks hold.
    /// Second, as many words in the box as possible: it ends in the earliest block that can hold it within the
    /// limits, and only runs on when none can.
    /// Under those, the least noticeable change: runs of words at the ends of paragraphs set tighter or looser;
    /// a uniform setting (leading included) only when they can't reach the count; the fewest and smallest
    /// adjustments, the end of the story first.
    fileprivate func fitStory(_ a: Article, blocks: [StoryBlockSpec], colWidth: CGFloat, tight known: Measure? = nil) -> (Fit, FitInfo, Measure) {
        let measure = measurer(a, blocks: blocks)
        let tight = known ?? measure(Fit(level: -Fit.comfortable))        // mid-drag, last time's serves for the room figure
        let m0 = measure(.neutral)
        let n = blocks.count
        var tightest: Measure?, loosest: Measure?
        func spill(_ m: Measure, past k: Int) -> Int { k + 1 < n ? m.perBlock[(k + 1)...].reduce(0) { $0 + $1.used } : 0 }
        /// Lines still needed for the story to end flush in block k: + to gain, − to lose; 0 when it does.
        func residual(_ m: Measure, endingIn k: Int) -> Int {
            let s = spill(m, past: k)
            if s > 0 { return -s }
            if m.overset > 0 { return -m.overset }
            return m.perBlock[...k].reduce(0) { $0 + $1.room } - m.used
        }
        /// Whether the limits can get the story to end in block k at all, before spending the real work.
        func feasible(endingIn k: Int) -> Bool {
            let r0 = residual(m0, endingIn: k)
            if r0 < 0 {
                if tightest == nil { tightest = measure(Fit(level: -Fit.limit)) }
                return spill(tightest!, past: k) == 0 && tightest!.overset == 0
            }
            if r0 > 0 {
                if loosest == nil { loosest = measure(Fit(level: Fit.limit)) }
                return residual(loosest!, endingIn: k) <= 0
            }
            return true
        }
        func solve(endingIn k: Int) -> (Fit, Measure)? {
            let r0 = residual(m0, endingIn: k)
            if r0 == 0 { return (.neutral, m0) }
            guard feasible(endingIn: k) else { return nil }
            let dir: Double = r0 > 0 ? 1 : -1
            var best: (fit: Fit, m: Measure, cost: Double)?
            for step in stride(from: 0.0, through: Fit.limit, by: 0.1) {
                let u = dir * step
                // a small change to every line is the least noticeable way to move the count: it costs a quarter
                // of what the same strength would cost on a run of words, so the uniform setting does the bulk and
                // the runs at paragraph ends only make up the last line or two
                let ucost = step * step * Double(max(1, m0.used)) / 4
                if let b = best, ucost >= b.cost { break }                        // nothing cheaper is left
                let base = step == 0 ? m0 : measure(Fit(level: u))
                var delta = residual(base, endingIn: k)
                if delta == 0 {
                    if best == nil || ucost < best!.cost { best = (Fit(level: u), base, ucost) }
                    continue
                }
                for _ in 0..<3 {                                                  // the paragraph model is a line or so off where blocks start
                    let tp = Date()
                    let planned = localPlan(a, delta: delta, base: u, width: colWidth)
                    searchStats.plans += 1; searchStats.planMs += Date().timeIntervalSince(tp) * 1000
                    guard let (plan, pcost) = planned else { break }
                    let fit = Fit(level: u, local: plan)
                    let m = measure(fit)
                    let off = residual(m, endingIn: k)
                    if off == 0 {
                        if best == nil || ucost + pcost < best!.cost { best = (fit, m, ucost + pcost) }
                        break
                    }
                    delta += off
                    if delta == 0 { break }
                }
            }
            return best.map { ($0.fit, $0.m) }
        }
        let natural = m0.perBlock.lastIndex { $0.used > 0 } ?? 0
        var result: (Fit, Measure)?
        for k in 0..<n {                                                          // the earliest block it can end in, flush
            if let r = solve(endingIn: k) { result = r; break }
        }
        let (fit, final) = result ?? {
            // flush is out of reach: house settings, and the overset or blank lines are flagged
            _ = natural
            return (Fit.neutral, m0)
        }()
        return (fit, info(a, blocks: blocks, colWidth: colWidth, fit: fit, final: final, tight: tight, measure: measure), tight)
    }

    /// Lines left unfilled in the blocks a story reaches.
    private static func blank(_ m: Measure) -> Int {
        m.perBlock.filter { $0.used > 0 }.reduce(0) { $0 + $1.room } - m.used
    }

    private func info(_ a: Article, blocks: [StoryBlockSpec], colWidth: CGFloat, fit: Fit, final: Measure, tight: Measure, measure: (Fit) -> Measure) -> FitInfo {
        let carrying = final.perBlock.indices.filter { final.perBlock[$0].used > 0 }
        let roomUsed = carrying.reduce(0) { $0 + final.perBlock[$1].room }
        let sq = Double(colWidth) / 5184                       // one point of one column, in square inches
        let need0 = Double(lineCount(a, start: 0, continuedFrom: nil, width: colWidth)) * Double(HouseStyle.leading)
        let needNow = Double(lineCount(a, start: 0, continuedFrom: nil, width: colWidth, fit: fit)) * Double(fit.leading)
        let tightLeading = Double(Fit(level: -Fit.comfortable).leading)
        // what it still needs is measured at the very tightest; what it could give up, at the comfortable tightest
        var short = 0.0
        if final.overset > 0 {
            let tightest = Fit(level: -Fit.limit)
            short = Double(measure(tightest).overset) * Double(tightest.leading) * sq
        }
        let lines0 = lineCount(a, start: 0, continuedFrom: nil, width: colWidth)
        return FitInfo(level: fit.strongest,
                       percent: need0 > 0 ? needNow / need0 - 1 : 0,
                       area: carrying.reduce(0) { $0 + Double(blocks[$1].frame.width * blocks[$1].frame.height) } / 5184,
                       spare: tight.overset > 0 ? 0 : max(0, Double(roomUsed) * Double(fit.leading) - Double(tight.used) * tightLeading) * sq,
                       short: short,
                       used: final.used, room: roomUsed, overset: final.overset,
                       blank: max(0, roomUsed - final.used), orphans: blocks.count - carrying.count,
                       uniform: fit.level, places: fit.local.count,
                       localLines: fit.local.isEmpty ? 0 : lineCount(a, start: 0, continuedFrom: nil, width: colWidth, fit: fit) - lines0)
    }

    /// With `GALLEY_LINES` set to a file, every body line set on a page is written there (story, available width,
    /// indent, hyphenated, text), for checking the IDML export's line breaks against Typeset's.
    static var lineLog: FileHandle? = ProcessInfo.processInfo.environment["GALLEY_LINES"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    /// With `GALLEY_DEBUG` set, every compose reports what it cost on stderr.
    static var profile = ProcessInfo.processInfo.environment["GALLEY_DEBUG"] != nil

    /// Compose every page in order. Pages whose inputs haven't changed come from the cache.
    /// `exact` (the default) works out every fit before returning. Without it, and with a background worker, a story
    /// whose fit isn't known yet is set at its last one and its page marked provisional, for the screen.
    func compose(_ issue: Issue, exact: Bool = true) -> [ComposedPage] {
        let t0 = Date()
        componentSource = issue
        var fullFits = 0, quickFits = 0, composedPages = 0, memoHit = false
        defer {
            if Thread.isMainThread { Self.stats.composes += 1; Self.stats.composeMs += Date().timeIntervalSince(t0) * 1000 }
            if Self.profile {
                FileHandle.standardError.write(String(format: "compose %.2f ms · %@fits full %d quick %d · pages set %d\n",
                                                      Date().timeIntervalSince(t0) * 1000, memoHit ? "memo · " : "", fullFits, quickFits, composedPages).data(using: .utf8)!)
            }
        }
        let deferFits = dragging
        let background = !exact && worker != nil
        if let m = memo[background], m.deferred == deferFits, m.generation == generation, m.issue == issue {
            memoHit = true; fits = m.fits; settings = m.settings; return m.pages
        }
        guard let layout = issue.layout else { fits = [:]; settings = [:]; memo = [:]; return [] }
        let articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extras = Dictionary(issue.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // body and whole-story frames in placed components set like story blocks, in the component's columns
        let componentBlocks = layout.pages.map { componentBlocks(on: $0, issue: issue, pageColumns: layout.columns, articles: articles) }
        let inComponent = Dictionary(componentBlocks.flatMap { $0 }.map { ($0.block.id, $0) }, uniquingKeysWith: { a, _ in a })
        let orders = layout.pages.enumerated().map { PageLayout.readingOrder($1.stories + componentBlocks[$0].map(\.block)) }
        var appearances: [Article.ID: [(page: Int, block: StoryBlock.ID)]] = [:]
        for i in layout.pages.indices {
            for b in orders[i] { appearances[b.article, default: []].append((i + 1, b.id)) }
        }
        let firstPage = appearances.mapValues { $0[0].page }
        var links: [StoryBlock.ID: (from: Int?, to: Int?)] = [:]
        for (_, list) in appearances {
            for (k, item) in list.enumerated() {
                links[item.block] = (k > 0 ? list[k - 1].page : nil, k + 1 < list.count ? list[k + 1].page : nil)
            }
        }
        let obstacles = layout.pages.map { self.obstacles($0, articles: articles) }

        // copyfit every story to the blocks it has
        var specs: [Article.ID: [(page: Int, block: StoryBlock, avoid: [CGRect], top: CGFloat?)]] = [:]
        let aligned = layout.pages.enumerated().map { alignedBodyTops($1, articles: articles, obstacles[$0]) }
        for (i, page) in layout.pages.enumerated() {
            for b in orders[i] {
                let av = inComponent[b.id].map { avoid(forComponentBlock: $0, obstacles[i]) } ?? avoid(for: b, on: page, obstacles[i])
                specs[b.article, default: []].append((i, b, av, aligned[i][b.id]))
            }
        }
        var storyFits: [Article.ID: Fit] = [:]
        var infos: [Article.ID: FitInfo] = [:]
        var provisional: Set<Article.ID> = []
        for (id, blocks) in specs {
            guard let a = articles[id] else { continue }
            var h = Hasher()
            h.combine(a); h.combine(layout.columns)
            for (p, b, av, top) in blocks {
                h.combine(p); h.combine(b); h.combine(links[b.id]?.from); h.combine(links[b.id]?.to); h.combine(top)
                h.combine(inComponent[b.id]?.gutter); h.combine(inComponent[b.id]?.bodyOnly)
                for r in av { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
            }
            let key = h.finalize()
            // a quick (mid-drag) fit is good for the same state while the drag lasts; the full search replaces it after
            if let c = fitCache[id], c.key == key, !(c.quick && !deferFits) { storyFits[id] = c.fit; infos[id] = c.info; continue }
            let specs = blocks.map {
                ($0.block.frame.rect, $0.block.columns, $0.block.headlineSize, $0.avoid, links[$0.block.id]?.from, links[$0.block.id]?.to, $0.block.bylineColumns, $0.top,
                 inComponent[$0.block.id]?.gutter ?? HouseStyle.gutter, inComponent[$0.block.id]?.bodyOnly ?? false)
            }
            if background, let worker {
                // set it at its last fit for now; the exact one is worked out off the main thread
                if let c = fitCache[id] { storyFits[id] = c.fit; infos[id] = c.info }
                provisional.insert(id)
                worker.submit(.init(id: id, key: key, article: a, specs: specs, colWidth: layout.grid.colWidth)) { [weak self] job, fit, info, tight in
                    guard let self else { return }
                    self.fitCache[job.id] = FitEntry(key: job.key, fit: fit, info: info, quick: false, tight: tight)
                    self.generation += 1
                    self.onFitsReady?()
                }
                continue
            }
            let tf = Date()
            let (fit, info, tight) = fitStory(a, blocks: specs, colWidth: layout.grid.colWidth, tight: deferFits ? fitCache[id]?.tight : nil)
            Self.stats.fits += 1; Self.stats.fitMs += Date().timeIntervalSince(tf) * 1000
            fitCache[id] = FitEntry(key: key, fit: fit, info: info, quick: deferFits, tight: tight)
            storyFits[id] = fit; infos[id] = info
            fullFits += 1
        }
        fits = infos
        settings = storyFits

        var cursors: [Article.ID: Int] = [:]
        var result: [ComposedPage] = []

        for (i, page) in layout.pages.enumerated() {
            let number = i + 1
            let blocks = orders[i]
            var h = Hasher()
            h.combine(page); h.combine(number); h.combine(layout.columns)
            if !page.components.isEmpty { h.combine(issue.componentVersions) }
            for b in blocks {
                h.combine(articles[b.article]); h.combine(cursors[b.article] ?? 0)
                h.combine(links[b.id]?.from); h.combine(links[b.id]?.to); h.combine(storyFits[b.article]?.key)
            }
            for s in page.insets { h.combine(s.article.flatMap { articles[$0] }); h.combine(s.extra.flatMap { extras[$0] }) }
            // what a component's frames show: a headline, caption, picture or ad not set in any block on the page
            for c in page.components { for f in c.fills { h.combine(f.article.flatMap { articles[$0] }); h.combine(f.extra.flatMap { extras[$0] }) } }
            for c in page.components { for f in c.fills { h.combine(f.article.flatMap { firstPage[$0] }) } }     // a teaser's "Page 5"
            let pageProvisional = blocks.contains { provisional.contains($0.article) }
            h.combine(pageProvisional)
            h.combine(issue.date); h.combine(issue.volume); h.combine(issue.edition)
            let key = h.finalize()
            if let cached = pageCache[page.id], cached.key == key {
                result.append(cached.page)
                cursors.merge(cached.out) { $1 }
                continue
            }

            let tp = Date()
            defer { Self.stats.pages += 1; Self.stats.pageMs += Date().timeIntervalSince(tp) * 1000 }
            let cp = ComposedPage(number: number, grid: layout.grid, isFront: page.isFront)
            cp.provisional = pageProvisional
            composedPages += 1
            cp.incoming = cursors
            var desks: [String] = []
            for id in blocks.map(\.article) + componentStories(on: page, issue: issue, pageColumns: layout.columns) {
                if let d = articles[id]?.desk.rawValue, !desks.contains(d) { desks.append(d) }
            }
            // the folio names the desk when the page is one desk's; a mixed page carries just its number
            cp.section = desks.count == 1 ? desks[0] : (desks.isEmpty ? "News" : "")
            let obs = obstacles[i]
            drawComponents(page, issue: issue, number: number, pageColumns: layout.columns, articles: articles, firstPage: firstPage, into: cp)
            for inset in page.insets {
                guard let g = obs.geoms[inset.id] else { continue }
                cp.insetFrames[inset.id] = g.full
                cp.pictureFrames[inset.id] = g.picture
                switch inset.kind {
                case .photo:
                    let path = inset.article.flatMap { articles[$0] }?.photos.first(where: { $0.id == inset.photo })?.path ?? ""
                    if let img = image(path) {
                        cp.ops.append(.image(img, g.picture, HouseStyle.photoOutline, inset.focus))
                    } else {
                        cp.ops.append(.missing(g.picture))
                    }
                    if let t = g.text, let r = g.textRect { cp.ops.append(.text(t, r.insetBy(dx: 0, dy: -2))) }
                case .extra:
                    if let e = inset.extra.flatMap({ extras[$0] }), let img = image(e.path) {
                        cp.ops.append(.fitted(img, g.picture))
                        cp.ops.append(.frame(g.picture, HouseStyle.photoOutline, HouseStyle.ink))     // the house hairline, as a photo has
                    } else {
                        cp.ops.append(.missing(g.picture))
                    }
                    if let t = g.text, let r = g.textRect { cp.ops.append(.text(t, r.insetBy(dx: 0, dy: -2))) }
                case .pullQuote:
                    cp.ops.append(.frame(g.picture, HouseStyle.pullQuoteRule, HouseStyle.ink))
                    if let t = g.text, let r = g.textRect { cp.ops.append(.text(t, r.insetBy(dx: 0, dy: -2))) }
                }
            }

            var out: [Article.ID: Int] = [:]
            for b in blocks {
                guard let a = articles[b.article] else { continue }
                let link = links[b.id]
                let inside = inComponent[b.id]
                let r = setBlock(a, frame: b.frame.rect, columns: b.columns, headlineSize: b.headlineSize,
                                 start: cursors[b.article] ?? 0, continuedFrom: link?.from, jumpTo: link?.to,
                                 avoid: inside.map { avoid(forComponentBlock: $0, obs) } ?? avoid(for: b, on: page, obs),
                                 fit: storyFits[b.article] ?? .neutral, bylineColumns: b.bylineColumns,
                                 bodyTop: aligned[i][b.id], gutter: inside?.gutter ?? HouseStyle.gutter, bodyOnly: inside?.bodyOnly ?? false, into: cp)
                cursors[b.article] = r.end
                out[b.article] = r.end
                if let inside { cp.componentBlockResults[inside.placed, default: [:]][inside.frame] = r; continue }
                cp.storyFrames[b.id] = b.frame.rect
                cp.blockResults[b.id] = r
            }
            for b in blocks where inComponent[b.id] == nil {
                guard let r = cp.blockResults[b.id], let a = articles[b.article] else { continue }
                let f = b.frame.rect
                if r.used == 0, r.start >= r.total, r.total > 0 {
                    // the story ended before it got here: this block holds nothing
                    cp.blanks.append(ComposedPage.Blank(at: CGPoint(x: f.maxX, y: f.maxY), lines: r.room, story: a.plainHeadline,
                                                        orphan: r.continuedFrom))
                } else if r.empty >= 3 {
                    cp.blanks.append(ComposedPage.Blank(at: CGPoint(x: f.maxX, y: f.maxY), lines: r.empty, story: a.plainHeadline))
                }
            }
            // the stories set in components' frames take part as the blocks they were (phase 7)
            let inFrames = ruleBlocks(on: page, cp, issue: issue, articles: articles)
            var rulePage = page
            rulePage.stories += inFrames.blocks
            for rule in Self.storyRules(rulePage, results: cp.blockResults.merging(inFrames.results) { a, _ in a }, around: obs.geoms.values.map(\.full) + inFrames.art) {
                cp.ops.append(.line(rule.from, rule.to, HouseStyle.storyRule, HouseStyle.ink))
            }
            cp.holes = Self.holes(on: page, covered: page.stories.map(\.frame.rect) + obs.geoms.values.map(\.full) + page.components.map(\.frame.rect), grid: layout.grid)
            pageCache[page.id] = (key, cp, out)
            result.append(cp)
        }
        memo[background] = (issue, deferFits, generation, result, infos, storyFits)
        return result
    }

    /// Parts of the live area, column by column, that no block or picture covers. Gaps under two and a half lines are ignored.
    static func holes(on page: PageLayout, covered: [CGRect], grid: Grid) -> [ComposedPage.Hole] {
        let top = page.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        let bottom = HouseStyle.bottom
        var strips: [[(CGFloat, CGFloat)]] = []
        for c in 0..<grid.columns {
            let x0 = grid.x(c), x1 = x0 + grid.colWidth
            let spans = covered.filter { $0.maxX > x0 + 1 && $0.minX < x1 - 1 }.map { (max(top, $0.minY), min(bottom, $0.maxY)) }
                .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            var gaps: [(CGFloat, CGFloat)] = []
            var y = top
            let minimum = 2.5 * HouseStyle.leading          // the gap between stacked stories is not a hole
            for (a, b) in spans {
                if a - y >= minimum { gaps.append((y, a)) }
                y = max(y, b)
            }
            if bottom - y >= minimum { gaps.append((y, bottom)) }
            strips.append(gaps)
        }
        // the same gap across neighbouring columns is one hole
        var out: [ComposedPage.Hole] = []
        var taken = Set<String>()
        for c in 0..<grid.columns {
            for (y0, y1) in strips[c] where !taken.contains("\(c)|\(y0)") {
                var last = c
                while last + 1 < grid.columns, strips[last + 1].contains(where: { abs($0.0 - y0) < 3 && abs($0.1 - y1) < 3 }) {
                    last += 1
                    if let m = strips[last].first(where: { abs($0.0 - y0) < 3 && abs($0.1 - y1) < 3 }) { taken.insert("\(last)|\(m.0)") }
                }
                let r = CGRect(x: grid.x(c), y: y0, width: grid.span(last - c + 1), height: y1 - y0)
                out.append(ComposedPage.Hole(rect: r, area: Double(r.width * r.height) / 5184))
            }
        }
        return out
    }
}

// MARK: - Background fitting

/// Copyfits stories on background threads, each with a composer of its own (TextKit objects stay on the thread
/// that made them). A story always goes to the same lane, so its fits come back in order; a request a newer one
/// has replaced is skipped, so a drag never queues up stale work. Lanes run side by side, so a fresh paper fits
/// several stories at once.
final class FitWorker {
    struct Job { let id: Article.ID; let key: Int; let article: Article; let specs: [Composer.StoryBlockSpec]; let colWidth: CGFloat }
    private let lanes: [(queue: DispatchQueue, composer: Composer)]
    private let lock = NSLock()
    private var requested: [Article.ID: Int] = [:]                 // the newest key asked for, per story

    init(lanes n: Int = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))) {
        lanes = (0..<n).map { (DispatchQueue(label: "typeset.fit.\($0)", qos: .userInitiated), Composer()) }
    }

    /// Work out a story's exact fit; `done` runs on the main thread. Asking again for the same state does nothing.
    func submit(_ job: Job, done: @escaping (Job, Fit, FitInfo, Composer.Measure) -> Void) {
        lock.lock()
        let already = requested[job.id] == job.key
        requested[job.id] = job.key
        lock.unlock()
        guard !already else { return }
        let lane = lanes[Int(UInt(bitPattern: job.id.hashValue) % UInt(lanes.count))]
        lane.queue.async { [self] in
            func stale() -> Bool { lock.lock(); defer { lock.unlock() }; return requested[job.id] != job.key }
            guard !stale() else { return }                                // a newer state has been asked for
            let c = lane.composer
            c.stopped = false
            c.searchStats = (0, 0, 0, 0, 0, 0)
            c.shouldStop = stale
            let t0 = Date()
            // TextKit raises an Objective-C exception when glyph generation fails; uncaught on this thread it
            // would take the whole app down. Caught, the story keeps the fit it had and the next change tries again.
            var result: (Fit, FitInfo, Composer.Measure)?
            if let reason = TypesetCatchException({ result = c.fitStory(job.article, blocks: job.specs, colWidth: job.colWidth) }) {
                FileHandle.standardError.write("fit of \(job.article.plainHeadline.prefix(40)) failed: \(reason)\n".data(using: .utf8)!)
                c.shouldStop = nil
                lock.lock(); if requested[job.id] == job.key { requested[job.id] = nil }; lock.unlock()   // so it's asked again
                return
            }
            guard let (fit, info, tight) = result else { c.shouldStop = nil; return }
            c.shouldStop = nil
            if Composer.profile {
                let s = c.searchStats
                FileHandle.standardError.write(String(format: "fit %@ %.0f ms%@ · %d measures %.0f ms · %d plans %.0f ms · %d paragraph layouts %.0f ms\n",
                                                      String(job.article.plainHeadline.prefix(24)), Date().timeIntervalSince(t0) * 1000,
                                                      c.stopped ? " (stopped: stale)" : "", s.measures, s.measureMs, s.plans, s.planMs,
                                                      s.paraLayouts, s.paraMs).data(using: .utf8)!)
            }
            guard !c.stopped else { return }
            DispatchQueue.main.async { done(job, fit, info, tight) }
        }
    }

    /// Forget what was asked, so the same state can be asked for again (after the cache was cleared).
    func reset() { lock.lock(); requested = [:]; lock.unlock() }
}

// MARK: - PDF

enum PDFExport {
    @discardableResult
    static func write(_ pages: [ComposedPage], to url: URL, guides: Bool = false) -> Bool {
        var box = CGRect(origin: .zero, size: HouseStyle.page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Typeset"] as CFDictionary) else { return false }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            page.draw(guides: guides)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }
}
