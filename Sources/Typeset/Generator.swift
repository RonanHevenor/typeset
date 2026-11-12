import AppKit

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

/// Lays out an example paper from the stories in priority order. The front page follows the house template;
/// every other page is generated: stories are packed in order into modules on the column grid, each module
/// sized to hold its story, with pictures and pull quotes placed in one of several house arrangements.
final class LayoutGenerator {
    /// A story, or the rest of one, waiting for a page.
    struct Item {
        var article: Article
        var start = 0
        var continuedFrom: Int?
        var photos: [Photo]
        var quote: Bool
    }

    enum Spot { case none, top, wide, bottom, middle }
    struct Variant { var spot: Spot; var second: Bool; var quote: Bool }

    /// A page arrangement: stories stacked top to bottom, or set side by side across the columns.
    indirect enum Slice { case story(Int); case stack([Slice]); case row([(Int, Slice)]) }

    struct Module { var item: Int; var frame: CGRect; var columns: Int; var headlineSize: CGFloat; var insets: [Inset]; var slack: Int; var lines: Int }

    /// One try at a page: which arrangement each story gets, and how large pictures run.
    struct Attempt { var picks: [UInt64]; var scale: CGFloat }

    let composer: Composer
    let issue: Issue
    let seed: UInt64
    private var rng: SplitMix64
    private(set) var grid = Grid(columns: 3)
    private(set) var charsPerLine = 0.0
    private let articles: [Article.ID: Article]
    private let debug = ProcessInfo.processInfo.environment["GALLEY_DEBUG"] != nil

    init(issue: Issue, composer: Composer, seed: UInt64, columns: Int? = nil) {
        self.issue = issue
        if let columns { grid = Grid(columns: columns) }
        self.composer = composer
        self.seed = seed
        rng = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D &+ 1)
        articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func run() -> IssueLayout {
        let stories = issue.articles.filter { $0.body.contains { !$0.trimmed.isEmpty } }
        let copy = Markup.plain(stories.flatMap(\.body).joined(separator: " "))
        let measured = HouseStyle.columns(averageCharWidth: HouseStyle.averageCharWidth(of: copy))
        grid = Grid(columns: measured.columns)
        charsPerLine = measured.charsPerLine

        let (front, jumps) = frontPage(stories)
        var pages = [front]
        var queue = stories.dropFirst(2).map { Item(article: $0, photos: $0.photos, quote: true) } + jumps
        while !queue.isEmpty {
            var page = PageLayout()
            page.components = issue.templateComponents(forPage: pages.count, isFront: false)
            pageTop = Self.top(of: page)
            // a component placed lower down on the template's page is planned around, as an ad is
            fixed = page.components.filter { $0.frame.rect.minY >= HouseStyle.insideTop }.map { Composer.wrap($0.frame.rect) }
            var next = nextPage(&queue, number: pages.count + 1)
            fixed = []
            next.components = page.components
            pages.append(next)
        }
        // the template's own pages are kept even when the stories don't reach them (a page of nothing but its
        // repeating components is an ordinary inside page, added only as the stories need it)
        while pages.count < issue.pagePlan.keptPageCount {
            var page = PageLayout()
            page.components = issue.templateComponents(forPage: pages.count, isFront: false)
            pages.append(page)
        }
        return IssueLayout(pages: pages, columns: grid.columns, charsPerLine: charsPerLine,
                           basis: issue.articles.map(\.id), seed: seed)
    }

    /// Pictures that stay where they are while a page is re-planned (its ads and graphics, and art of stories not
    /// on it): the stories are sized to wrap around them, as they will when set.
    private var fixed: [CGRect] = []
    /// Where the page being planned starts: the house top, or under the components placed across it.
    private var pageTop: CGFloat = HouseStyle.insideTop

    /// Where a page's stories start: the house top for the page, or just under a placed component that reaches
    /// below it (display type keeps `displayClearance` from a picture's edge). Only a component that starts above
    /// the house top (a Header, a Folio) moves the top; one placed lower down is planned around, as `fixed`.
    static func top(of page: PageLayout) -> CGFloat {
        let house = page.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop
        return page.components.filter { $0.frame.rect.minY < house }.map { $0.frame.rect.maxY + Composer.displayClearance }.reduce(house, max)
    }

    /// Re-plan one inside page with the same stories and pictures. Ads, graphics and other stories' art placed on
    /// the page stay put; the page's own stories are planned around them. Placed components stay too, with what fills them.
    func reshuffle(_ page: PageLayout, number: Int, incoming: [Article.ID: Int], continuedFrom: [Article.ID: Int]) -> PageLayout? {
        let own = Set(page.stories.map(\.article))
        let kept = page.insets.filter { $0.kind == .extra || !($0.article.map(own.contains) ?? false) }
        let extras = Dictionary(issue.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        fixed = kept.compactMap { i in
            composer.geometry(i, i.article.flatMap { articles[$0] }, i.extra.flatMap { extras[$0] }).map { Composer.wrap($0.full) }
        } + page.components.map { Composer.wrap($0.frame.rect) }      // placed components stay put, with their fills
        pageTop = Self.top(of: page)
        defer { fixed = []; pageTop = HouseStyle.insideTop }
        let items = page.stories.compactMap { b -> Item? in
            guard let a = articles[b.article] else { return nil }
            let shown = Set(page.insets.filter { $0.article == a.id && $0.kind == .photo }.compactMap(\.photo))
            return Item(article: a, start: incoming[a.id] ?? 0, continuedFrom: continuedFrom[a.id],
                        photos: a.photos.filter { shown.contains($0.id) },
                        quote: page.insets.contains { $0.kind == .pullQuote && $0.article == a.id })
        }
        guard !items.isEmpty, let plan = bestPlan(items) else { return nil }
        var p = self.page(from: plan, items: items)
        p.id = page.id
        p.insets += kept
        p.components = page.components
        return p
    }

    // MARK: front page

    private func frontPage(_ stories: [Article]) -> (PageLayout, [Item]) {
        typealias F = HouseStyle.Front
        var page = PageLayout(isFront: true)
        page.components = issue.templateComponents(forPage: 0, isFront: true)     // the template's front page (the Header)
        let top = Self.top(of: page)
        // a component placed lower down on the template's front page is planned around, as on an inside page: the
        // stories wrap around it, and a picture that would land on it goes inside with the jump instead
        fixed = page.components.filter { $0.frame.rect.minY >= F.leadTop }.map { Composer.wrap($0.frame.rect) }
        defer { fixed = [] }
        var jumps: [Item] = []
        let slots: [(top: CGFloat, bottom: CGFloat, size: CGFloat)] = stories.count > 1
            ? [(top, max(top + 1, F.leadBottom), HouseStyle.frontLeadHeadline), (max(top, F.secondTop), HouseStyle.bottom, HouseStyle.frontSecondHeadline)]
            : [(top, HouseStyle.bottom, HouseStyle.frontLeadHeadline)]
        for (k, slot) in slots.enumerated() where k < stories.count {
            let a = stories[k]
            let frame = CGRect(x: HouseStyle.margin, y: slot.top, width: HouseStyle.liveWidth, height: slot.bottom - slot.top)
            page.stories.append(StoryBlock(article: a.id, frame: Box(frame), columns: grid.columns, headlineSize: slot.size))
            var used: Set<Photo.ID> = []
            if let p = a.photos.first {
                let r: CGRect
                if k == 0 {
                    // the lead picture takes the right-hand columns under the headline
                    let n = max(1, grid.columns - 1)
                    let w = grid.span(n)
                    let h = (w / composer.aspect(p)).clamped(0.45 * w, min(0.7 * w, 300))
                    let top = frame.minY + composer.headlineHeight(a, width: frame.width, size: slot.size) + HouseStyle.headlineGap + 4
                    r = CGRect(x: grid.x(grid.columns - n), y: top, width: w, height: h)
                } else {
                    // the second story's picture sits at the foot of the first column
                    let w = grid.colWidth
                    let h = (w / composer.aspect(p)).clamped(0.5 * w, min(w, 230))
                    r = CGRect(x: grid.x(0), y: frame.maxY - h - captionHeight(p, width: w), width: w, height: h)
                }
                if !fixed.contains(where: { $0.intersects(r) }) {
                    page.insets.append(Inset(kind: .photo, article: a.id, photo: p.id, frame: Box(r)))
                    used.insert(p.id)
                }
            }
            // whatever doesn't fit on the front jumps inside
            var r = composer.setBlock(a, frame: frame, columns: grid.columns, headlineSize: slot.size, start: 0,
                                      continuedFrom: nil, jumpTo: 99, avoid: wrapRects(page.insets) + fixed, into: nil)
            var size = slot.size
            var tries = 0
            while !r.jumped, r.empty > 4, tries < 4 {
                // a short story: a bigger picture, then a bigger headline, before blank lines show
                tries += 1
                if let k = page.insets.lastIndex(where: { $0.article == a.id && $0.kind == .photo }) {
                    var pr = page.insets[k].frame.rect
                    let grow = min(CGFloat(r.empty) * HouseStyle.leading, pr.width * 1.1 - pr.height)
                    if grow > 2 {
                        pr.size.height += grow
                        if k > 0 || pr.maxY > frame.maxY - 80 { pr.origin.y = min(pr.minY, frame.maxY - pr.height - captionHeight(a.photos[0], width: pr.width)) }
                    }
                    if grow > 2, !fixed.contains(where: { $0.intersects(pr) }) {
                        page.insets[k].frame = Box(pr)
                    } else { size = min(size + 4, 44) }
                } else { size = min(size + 4, 44) }
                page.stories[page.stories.count - 1].headlineSize = size
                r = composer.setBlock(a, frame: frame, columns: grid.columns, headlineSize: size, start: 0,
                                      continuedFrom: nil, jumpTo: 99, avoid: wrapRects(page.insets) + fixed, fit: Fit(level: 1), into: nil)
            }
            if r.jumped, let fitted = keepOnFront(a, frame: frame, size: size, page: &page) { r = fitted }
            if r.jumped {
                jumps.append(Item(article: a, start: r.end, continuedFrom: 1, photos: a.photos.filter { !used.contains($0.id) }, quote: true))
            }
        }
        return (page, jumps)
    }

    /// Front stories don't have to jump. One that runs a little long is set tight (copyfit's comfortable range)
    /// and, if that isn't enough, its picture comes down to the smallest the front allows. If it still runs over by
    /// less than `frontJumpMinimum` lines, it ends on the front with the online line rather than jumping a stub
    /// inside: a continuation that copyfitting can empty again leaves a headline and byline with nothing under them.
    /// Returns the setting that keeps the story on the front, or nil when it should jump.
    private func keepOnFront(_ a: Article, frame: CGRect, size: CGFloat, page: inout PageLayout) -> Composer.BlockResult? {
        let tight = Fit(level: -Fit.comfortable)
        func set() -> Composer.BlockResult {
            composer.setBlock(a, frame: frame, columns: grid.columns, headlineSize: size, start: 0,
                              continuedFrom: nil, jumpTo: nil, avoid: wrapRects(page.insets) + fixed, fit: tight, into: nil)
        }
        var r = set()
        if r.end >= r.total { return r }
        let before = page.insets
        if let k = page.insets.lastIndex(where: { $0.article == a.id && $0.kind == .photo }),
           let photo = a.photos.first(where: { $0.id == page.insets[k].photo }) {
            var pr = page.insets[k].frame.rect
            let lead = pr.width > grid.colWidth + 1
            let smallest = (lead ? 0.45 : 0.5) * pr.width
            if pr.height > smallest + 2 {
                let anchoredBottom = !lead
                let bottom = pr.maxY
                pr.size.height = max(smallest, pr.height - CGFloat(r.oversetLines) * HouseStyle.leading)
                if anchoredBottom { pr.origin.y = frame.maxY - pr.height - captionHeight(photo, width: pr.width) }
                else { pr.origin.y = min(pr.minY, bottom - pr.height) }
                page.insets[k].frame = Box(pr)
                r = set()
                if r.end >= r.total { return r }
            }
        }
        if r.oversetLines < Self.frontJumpMinimum { return r }
        page.insets = before                          // it jumps after all: the picture keeps its size
        return nil
    }

    /// The fewest lines worth jumping inside for: below this a front story ends on the front instead.
    static let frontJumpMinimum = 12

    // MARK: inside pages

    /// Fill a page with the next stories in priority order. Stories are chosen with pictures at their
    /// natural size; once the page's stories are settled, pictures grow into whatever room is left.
    private func nextPage(_ queue: inout [Item], number: Int) -> PageLayout {
        var chosen: [Item] = []
        var plan: [Module]?
        var skipped = 0
        var i = 0
        while i < queue.count, chosen.count < 4 {
            let candidate = chosen + [queue[i]]
            if let p = bestPlan(candidate, grow: false) {
                chosen = candidate
                plan = p
                queue.remove(at: i)
                continue
            }
            guard plan != nil else { break }
            // the next story doesn't fit: try a shorter one from just below it in the order
            if skipped < 3 { i += 1; skipped += 1; continue }
            break
        }
        if !chosen.isEmpty, let final = bestPlan(chosen) ?? plan { return page(from: final, items: chosen) }
        // a story too long for any page of its own takes the page and jumps to the next
        let item = queue.removeFirst()
        let (page, rest) = fullPage(item, number: number)
        if let rest { queue.insert(rest, at: 0) }
        return page
    }

    private func fullPage(_ item: Item, number: Int) -> (PageLayout, Item?) {
        let frame = CGRect(x: HouseStyle.margin, y: pageTop, width: HouseStyle.liveWidth, height: HouseStyle.bottom - pageTop)
        let n = grid.columns
        let size = headlineSize(item.article, width: frame.width, columns: n)
        let insets = place(item, in: frame, columns: n, variant: Variant(spot: item.photos.isEmpty ? .none : .top, second: false, quote: false), headlineSize: size)
        var page = PageLayout()
        page.stories = [StoryBlock(article: item.article.id, frame: Box(frame), columns: n, headlineSize: size)]
        page.insets = insets
        let r = composer.setBlock(item.article, frame: frame, columns: n, headlineSize: size, start: item.start,
                                  continuedFrom: item.continuedFrom, jumpTo: number + 1, avoid: wrapRects(insets), into: nil)
        guard r.jumped else { return (page, nil) }
        let used = Set(insets.compactMap(\.photo))
        return (page, Item(article: item.article, start: r.end, continuedFrom: number,
                           photos: item.photos.filter { !used.contains($0.id) }, quote: item.quote))
    }

    private func page(from modules: [Module], items: [Item]) -> PageLayout {
        var p = PageLayout()
        for m in modules.sorted(by: { $0.item < $1.item }) {
            p.stories.append(StoryBlock(article: items[m.item].article.id, frame: Box(m.frame), columns: m.columns,
                                        headlineSize: m.headlineSize))
            p.insets += m.insets
        }
        return p
    }

    /// How much of the page's body space the modules' text uses.
    private func fill(_ modules: [Module]) -> Double {
        let room = Double(grid.columns) * Double((HouseStyle.bottom - pageTop) / HouseStyle.leading)
        return 1 - whitespace(modules) / room
    }

    /// Empty body lines: slack inside modules plus the space under the lowest module in each column.
    private func whitespace(_ modules: [Module]) -> Double {
        var s = modules.reduce(0.0) { $0 + Double($1.slack) }
        for c in 0..<grid.columns {
            let x = grid.x(c) + 1
            let bottom = modules.filter { $0.frame.minX <= x && $0.frame.maxX >= x }.map(\.frame.maxY).max() ?? pageTop
            s += Double(max(0, HouseStyle.bottom - bottom) / HouseStyle.leading)
        }
        return s
    }

    /// Try every arrangement with several picture placements, running pictures larger while the page
    /// has room; pick at random among the tightest.
    private func bestPlan(_ items: [Item], grow: Bool = true) -> [Module]? {
        var plans: [(score: Double, modules: [Module])] = []
        for t in templates(items.count) {
            for _ in 0..<5 {
                let picks = items.map { _ in rng.next() }
                var best: (score: Double, modules: [Module])?
                for scale: CGFloat in grow ? [1, 1.2, 1.4, 1.6, 1.8] : [1] {
                    guard let ms = realize(t, cols: 0..<grid.columns, top: pageTop, bottom: HouseStyle.bottom,
                                           items: items, attempt: Attempt(picks: picks, scale: scale)) else { break }
                    // a story's own pictures don't land on an ad or graphic that stays on the page
                    if !fixed.isEmpty, ms.contains(where: { m in m.insets.contains { i in fixed.contains { $0.intersects(i.frame.rect) } } }) { continue }
                    let s = score(ms)
                    if best == nil || s < best!.score { best = (s, ms) }
                }
                if let best { plans.append(best) }
            }
        }
        if debug { print("   plan \(items.map { $0.article.plainHeadline.prefix(18) }): \(plans.count) fit, best \(plans.map(\.score).min() ?? -1)") }
        guard let best = plans.min(by: { $0.score < $1.score }) else { return nil }
        let good = plans.filter { $0.score <= best.score + 4 }
        return justify(good.randomElement(using: &rng)!.modules, items: items)
    }

    /// White space left on the page, in body lines, plus penalties for shapes that read badly and for space
    /// at a column foot that the story above can't loosen into.
    private func score(_ modules: [Module]) -> Double {
        var s = whitespace(modules)
        for m in modules {
            if m.columns == 1 && m.lines > 100 { s += Double(m.lines - 100) * 0.5 }     // a long ribbon of one column
            if m.frame.height < 160 { s += 40 }                                          // a stub
            let perColumn = Double(m.lines) / Double(m.columns)
            if perColumn < 12 { s += (12 - perColumn) * Double(m.columns) * 1.5 }         // a few lines strung across a wide head
        }
        let g = grid
        for c in 0..<g.columns {
            let x = g.x(c) + 1
            guard let m = modules.filter({ $0.frame.minX <= x && $0.frame.maxX >= x }).max(by: { $0.frame.maxY < $1.frame.maxY }) else { continue }
            let gap = Double(HouseStyle.bottom - m.frame.maxY) / Double(HouseStyle.leading)
            let absorbable = Double(m.lines) / Double(m.columns) * 0.07 + (m.insets.isEmpty ? 0 : 3)
            if gap > absorbable { s += (gap - absorbable) * 3 }
        }
        return s
    }

    /// Run every module with nothing below it down to the foot of the page. Copyfitting loosens its text to fill
    /// a little; more than that goes into a bigger picture, then a bigger headline.
    private func justify(_ modules: [Module], items: [Item]) -> [Module] {
        var ms = modules
        for i in ms.indices {
            let f = ms[i].frame
            let below = ms.indices.contains { j in
                j != i && ms[j].frame.minY >= f.maxY - 1 && ms[j].frame.maxX > f.minX + 1 && ms[j].frame.minX < f.maxX - 1
            }
            guard !below else { continue }
            let spare = HouseStyle.bottom - f.maxY
            guard spare > 1 else { continue }
            ms[i].frame.size.height += spare
            ms[i].slack += Int(spare / HouseStyle.leading)
            absorb(&ms[i], spare: spare, item: items[ms[i].item])
        }
        return ms
    }

    /// Soak up space a story can't fill by loosening alone: grow its picture, pull a quote, then grow its headline.
    private func absorb(_ m: inout Module, spare: CGFloat, item: Item) {
        let absorbable = m.frame.height * 0.06                    // what copyfitting can loosen into
        var extra = spare - absorbable
        guard extra > HouseStyle.leading else { return }
        let q = item.article.pullQuote.trimmed
        if extra > 60, !q.isEmpty, !m.insets.contains(where: { $0.kind == .pullQuote }) {
            let colW = grid.colWidth
            let t = Composer.pullQuote(q, width: colW)
            let h = composer.height(of: t, width: colW - 20) + 20
            let hh = composer.headlineHeight(item.article, width: m.frame.width, size: m.headlineSize)
            let bodyTop = m.frame.minY + hh + 7
            let bodyH = m.frame.maxY - bodyTop
            if h < bodyH * 0.5 {
                for col in (m.columns >= 3 ? [1, 2, 0] : m.columns == 2 ? [1, 0] : [0]) {
                    let x = m.frame.minX + CGFloat(col) * (colW + HouseStyle.gutter)
                    let y = bodyTop + ((bodyH * 0.45 - h / 2) / HouseStyle.leading).rounded() * HouseStyle.leading
                    let r = CGRect(x: x, y: max(bodyTop + HouseStyle.leading, y), width: colW, height: h)
                    if !m.insets.contains(where: { $0.frame.rect.insetBy(dx: -12, dy: -24).intersects(r) }),
                       !fixed.contains(where: { $0.intersects(r) }) {     // nor onto what stays put on a re-planned page
                        m.insets.append(Inset(kind: .pullQuote, article: item.article.id, photo: nil, frame: Box(r)))
                        extra -= h + 20
                        break
                    }
                }
            }
        }
        guard extra > HouseStyle.leading else { return }
        if let k = m.insets.firstIndex(where: { $0.kind == .photo }) {
            var r = m.insets[k].frame.rect
            let atFoot = r.maxY > m.frame.maxY - spare - 60
            let grow = min(extra, r.width * 1.1 - r.height)        // no taller than it is wide, and a bit
            if grow > 0 {
                r.size.height += grow
                if atFoot { r.origin.y = m.frame.maxY - r.height - 24 }
            }
            // the grown picture keeps clear of what stays put on a re-planned page (ads, graphics, components)
            if grow > 0, !fixed.contains(where: { $0.intersects(r) }) {
                m.insets[k].frame = Box(r)
                extra -= grow
            }
        }
        if extra > 40 { m.headlineSize = min(m.headlineSize + 6, 48) }
    }

    private func templates(_ k: Int) -> [Slice] {
        let c = grid.columns, wide = c - 1
        var t: [Slice]
        switch k {
        case 1:
            return [.story(0)]
        case 2:
            t = [.stack([.story(0), .story(1)])]
            if c >= 2 { t += [.row([(wide, .story(0)), (1, .story(1))]), .row([(1, .story(1)), (wide, .story(0))])] }
        case 3:
            t = [.stack([.story(0), .story(1), .story(2)])]
            if c >= 2 {
                t += [.stack([.story(0), .row([(wide, .story(1)), (1, .story(2))])]),
                      .stack([.story(0), .row([(1, .story(2)), (wide, .story(1))])]),
                      .row([(wide, .story(0)), (1, .stack([.story(1), .story(2)]))]),
                      .row([(wide, .stack([.story(0), .story(1)])), (1, .story(2))])]
            }
        default:
            t = [.stack([.story(0), .story(1), .story(2), .story(3)])]
            if c == 3 { t.append(.stack([.story(0), .row([(1, .story(1)), (1, .story(2)), (1, .story(3))])])) }
            if c >= 2 {
                t += [.stack([.story(0), .story(1), .row([(wide, .story(2)), (1, .story(3))])]),
                      .row([(wide, .stack([.story(0), .story(1)])), (1, .stack([.story(2), .story(3)]))]),
                      .stack([.story(0), .row([(wide, .stack([.story(1), .story(2)])), (1, .story(3))])])]
            }
        }
        return t
    }

    private func realize(_ s: Slice, cols: Range<Int>, top: CGFloat, bottom: CGFloat, items: [Item], attempt: Attempt) -> [Module]? {
        switch s {
        case .story(let i):
            return module(items[i], index: i, cols: cols, top: top, bottom: bottom, attempt: attempt).map { [$0] }
        case .stack(let children):
            var y = top
            var out: [Module] = []
            for (k, child) in children.enumerated() {
                if k == children.count - 1 {
                    guard let rest = realize(child, cols: cols, top: y, bottom: bottom, items: items, attempt: attempt) else { return nil }
                    return out + rest
                }
                guard case .story(let i) = child,
                      let m = module(items[i], index: i, cols: cols, top: y, bottom: bottom - 160, attempt: attempt) else { return nil }
                out.append(m)
                y = m.frame.maxY + HouseStyle.moduleGap
            }
            return out
        case .row(let parts):
            var c = cols.lowerBound
            var out: [Module] = []
            for (n, child) in parts {
                guard let ms = realize(child, cols: c..<(c + n), top: top, bottom: bottom, items: items, attempt: attempt) else { return nil }
                out += ms
                c += n
            }
            return out
        }
    }

    /// Set a story in the shortest module that holds it, with its pictures placed as the attempt picks.
    private func module(_ item: Item, index: Int, cols: Range<Int>, top: CGFloat, bottom: CGFloat, attempt: Attempt) -> Module? {
        let n = cols.count
        let options = variants(item, columns: n)
        let v = options[Int(attempt.picks[index] % UInt64(options.count))]
        let x = grid.x(cols.lowerBound), w = grid.span(n)
        let size = headlineSize(item.article, width: w, columns: n)
        let need = composer.lineCount(item.article, start: item.start, continuedFrom: item.continuedFrom, width: grid.colWidth)

        func evaluate(_ h: CGFloat) -> (fits: Bool, insets: [Inset], room: Int) {
            let frame = CGRect(x: x, y: top, width: w, height: h)
            let insets = place(item, in: frame, columns: n, variant: v, headlineSize: size, scale: attempt.scale)
            let g = composer.blockGeometry(item.article, frame: frame, columns: n, headlineSize: size, avoid: wrapRects(insets) + fixed, draw: false)
            let room = composer.capacity(g, jump: false).reduce(0, +)
            return (room >= need, insets, room)
        }

        let maxH = bottom - top
        guard maxH > 100 else { return nil }
        var best = evaluate(maxH)
        guard best.fits else { return nil }
        var lo: CGFloat = 60, hi = maxH
        while hi - lo > 2 {
            let mid = ((lo + hi) / 2).rounded()
            let r = evaluate(mid)
            if r.fits { hi = mid; best = r } else { lo = mid }
        }
        return Module(item: index, frame: CGRect(x: x, y: top, width: w, height: hi), columns: n, headlineSize: size,
                      insets: best.insets, slack: best.room - need, lines: need)
    }

    /// The house size for a module's headline, stepped down until it sets in two lines (three in one column).
    private func headlineSize(_ a: Article, width: CGFloat, columns n: Int) -> CGFloat {
        let base = HouseStyle.headlineSize(columns: n)
        let maxLines: CGFloat = n == 1 ? 3 : 2
        var size = base
        while size > base - 8, composer.headlineHeight(a, width: width, size: size) > size * 1.04 * maxLines + 1 { size -= 2 }
        return size
    }

    private func variants(_ item: Item, columns n: Int) -> [Variant] {
        let spots: [Spot]
        if item.photos.isEmpty { spots = [.none] }
        else if n == 1 { spots = [.top, .bottom] }
        else if n == 2 { spots = [.top, .wide, .bottom] }
        else { spots = [.top, .wide, .bottom, .middle] }
        let seconds = item.photos.count > 1 && n >= 2 ? [true, false] : [false]
        let quotes = item.quote && !item.article.pullQuote.trimmed.isEmpty && n >= 2 ? [true, false] : [false]
        return spots.flatMap { s in seconds.flatMap { second in quotes.map { Variant(spot: s, second: second, quote: $0) } } }
    }

    /// Put a story's pictures and pull quote in a module according to the variant.
    private func place(_ item: Item, in m: CGRect, columns n: Int, variant v: Variant, headlineSize: CGFloat, scale: CGFloat = 1) -> [Inset] {
        var out: [Inset] = []
        let colW = grid.colWidth
        func x(_ i: Int) -> CGFloat { m.minX + CGFloat(i) * (colW + HouseStyle.gutter) }
        let hh = composer.headlineHeight(item.article, width: m.width, size: headlineSize)
        let bodyTop = m.minY + hh + (hh > 0 ? HouseStyle.headlineGap : 0)
        let bodyH = m.maxY - bodyTop
        func onGrid(_ y: CGFloat) -> CGFloat { bodyTop + ((y - bodyTop) / HouseStyle.leading).rounded() * HouseStyle.leading }
        func height(_ p: Photo, _ w: CGFloat, share: CGFloat) -> CGFloat {
            (w / composer.aspect(p) * scale).clamped(0.42 * w, min(scale > 1 ? 0.95 * w : 0.85 * w, max(60, bodyH * min(0.7, share * scale))))
        }
        /// A picture's frame on the line grid: its top where a line ends plus the clearance above a picture, its
        /// height trimmed (the crop absorbs it) so the text under its caption starts on a line, 10 pt clear.
        func gridded(_ r: CGRect, caption cap: CGFloat, anchorBottom: Bool) -> CGRect {
            Composer.onLineGrid(r, caption: cap, bodyTop: bodyTop, pitch: HouseStyle.leading, anchorBottom: anchorBottom)
        }
        var taken: [CGRect] = []

        if v.spot != .none, let p = item.photos.first {
            let span: Int, first: Int
            switch v.spot {
            case .wide: span = n; first = 0
            case .middle: span = 1; first = n >= 3 ? 1 : n - 1
            default: span = max(1, n - 1); first = n - span
            }
            let w = grid.span(span)
            let h = height(p, w, share: 0.5)
            let cap = captionHeight(p, width: w)
            let y: CGFloat
            switch v.spot {
            case .bottom: y = m.maxY - h - cap
            case .middle: y = onGrid(bodyTop + bodyH * 0.32)
            default: y = bodyTop + 4
            }
            let r = gridded(CGRect(x: x(first), y: y, width: w, height: h), caption: cap, anchorBottom: v.spot == .bottom)
            out.append(Inset(kind: .photo, article: item.article.id, photo: p.id, frame: Box(r)))
            taken.append(CGRect(x: r.minX, y: r.minY, width: w, height: r.height + cap))
        }
        if v.second, item.photos.count > 1, n >= 2 {
            let p = item.photos[1]
            let h = height(p, colW, share: 0.35)
            let cap = captionHeight(p, width: colW)
            let r = gridded(CGRect(x: x(0), y: m.maxY - h - cap, width: colW, height: h), caption: cap, anchorBottom: true)
            let full = CGRect(x: r.minX, y: r.minY, width: colW, height: r.height + cap)
            if r.minY > bodyTop + 120, !taken.contains(where: { $0.insetBy(dx: -12, dy: -24).intersects(full) }) {
                out.append(Inset(kind: .photo, article: item.article.id, photo: p.id, frame: Box(r)))
                taken.append(full)
            }
        }
        if v.quote, n >= 2, bodyH > 420 {
            let q = item.article.pullQuote.trimmed
            let t = Composer.pullQuote(q, width: colW)
            let boxH = composer.height(of: t, width: colW - 20) + 20
            if boxH < bodyH * 0.4 {
                for col in (n >= 3 ? [1, 2, 0] : [1, 0]) {
                    let r = CGRect(x: x(col), y: onGrid(bodyTop + bodyH * 0.45 - boxH / 2), width: colW, height: boxH)
                    if !taken.contains(where: { $0.insetBy(dx: -12, dy: -24).intersects(r) }) {
                        out.append(Inset(kind: .pullQuote, article: item.article.id, photo: nil, frame: Box(r)))
                        break
                    }
                }
            }
        }
        return out
    }

    // MARK: helpers

    private func captionHeight(_ p: Photo, width: CGFloat) -> CGFloat {
        Composer.caption(p, width: width).map { composer.height(of: $0, width: width) + 4 } ?? 0
    }

    private func wrapRects(_ insets: [Inset]) -> [CGRect] {
        insets.compactMap { i in composer.geometry(i, i.article.flatMap { articles[$0] }).map { Composer.wrap($0.full) } }
    }
}
