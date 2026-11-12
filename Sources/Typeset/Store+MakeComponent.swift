import AppKit

// Make Component… (phase 7). A selection of blocks, pictures, pull quotes and ads on one page becomes a new
// component: each item turns into typed frames placed exactly where the item draws its parts, so the component,
// placed in the selection's spot and filled with what was there, sets the page as it was. The component is saved
// with its frames empty (in the issue; it has no file until Save as New Version asks where), the items come off
// the page, all in one undo step, and the in-place editor opens on the placement.
//
// The geometry comes from the composer, not from the stored frames: a block's kicker, headline, byline and body
// sit where `blockGeometry` puts them on this page (bylines held level with a neighbour's included); a picture's
// caption hangs where `geometry` hangs it. The body frame starts where the block's text starts and keeps the
// block's width, so it sets in the same columns; a story that continues from or jumps to another page keeps its
// "Continued from" and jump line, since the composer links a body frame's story like any block's.
extension IssueStore {
    /// One story letter per article in the selection: A, B, C… in the blocks' reading order.
    static func storyLetter(_ n: Int) -> String {
        var s = "", k = n
        repeat { s = String(UnicodeScalar(UInt8(65 + k % 26))) + s; k = k / 26 - 1 } while k >= 0
        return s
    }

    /// What Make Component builds from a selection, before anything changes.
    struct ComponentPlan {
        var component: Component
        var origin: CGPoint
        var fills: [Fill]
        var taken: Set<LayoutSelection>      // the items that come off the page (pictures inside selected blocks included)
    }

    /// Plans the component for `selection` on its page: nil when nothing in it can become a frame.
    func planComponent(from selection: Set<LayoutSelection>, name: String) -> (page: Int, plan: ComponentPlan)? {
        guard let layout = issue.layout, let page = selection.lazy.compactMap({ self.page(of: $0) }).first else { return nil }
        let pl = layout.pages[page]
        _ = displayPages                                             // the composer's obstacles want its extras in hand
        let articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let extras = Dictionary(issue.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // the items on this page, blocks in reading order; a block carries the pictures of its story lying on it
        var blocks: [StoryBlock] = []
        var insetIDs = Set<Inset.ID>()
        for item in selection where self.page(of: item) == page {
            switch item {
            case .block(let id):
                if let b = pl.stories.first(where: { $0.id == id }) {
                    blocks.append(b)
                    for i in insets(with: b, on: page) { insetIDs.insert(i.id) }
                }
            case .inset(let id): insetIDs.insert(id)
            case .component: break                                   // no components inside components
            }
        }
        // only what has something to draw becomes frames and comes off the page: a block whose story is gone, a
        // pull quote whose story has none, a photo gone from its story or an ad gone from the issue stays where it is
        let obs = composer.obstacles(pl, articles: articles)
        blocks = PageLayout.readingOrder(blocks.filter { articles[$0.article] != nil })
        let insetList = pl.insets.filter { i in
            guard insetIDs.contains(i.id), obs.geoms[i.id] != nil else { return false }
            switch i.kind {
            case .photo, .pullQuote: return i.article.flatMap { articles[$0] } != nil
            case .extra: return i.extra.flatMap { extras[$0] } != nil
            }
        }
        guard !blocks.isEmpty || !insetList.isEmpty else { return nil }

        // the box round everything, as drawn
        var bounds = CGRect.null
        for b in blocks { bounds = bounds.union(b.frame.rect) }
        for i in insetList { if let g = obs.geoms[i.id] { bounds = bounds.union(g.full) } }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let origin = bounds.origin
        func rel(_ r: CGRect) -> Box { Box(x: r.minX - origin.x, y: r.minY - origin.y, w: r.width, h: r.height) }

        var elements: [Element] = []
        var fills: [Fill] = []
        var letters: [Article.ID: String] = [:]
        for b in blocks where letters[b.article] == nil && articles[b.article] != nil { letters[b.article] = Self.storyLetter(letters.count) }

        // story blocks: kicker, headline, author, author title and body, where the composer draws them
        let aligned = composer.alignedBodyTops(pl, articles: articles, obs)
        for b in blocks {
            guard let a = articles[b.article], let letter = letters[b.article] else { continue }
            let f = b.frame.rect
            let g = composer.blockGeometry(a, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: composer.avoid(for: b, on: pl, obs),
                                           bylineColumns: b.bylineColumns, bodyTop: aligned[b.id], draw: true)
            if let k = g.kicker { elements.append(.frame(Frame(type: .kicker, box: rel(k), link: letter))) }
            let headTop = g.headTop + (g.kicker?.height ?? 0)
            let headBottom = g.bodyTop - HouseStyle.headlineGap
            if g.headline != nil, headBottom > headTop {
                elements.append(.frame(Frame(type: .headline, box: rel(CGRect(x: f.minX, y: headTop, width: f.width, height: headBottom - headTop)), link: letter,
                                                      size: g.headlineSize > 0 ? g.headlineSize : b.headlineSize)))
            }
            if let by = g.byline {
                if a.authorTitle.trimmed.isEmpty {
                    elements.append(.frame(Frame(type: .author, box: rel(by), link: letter)))
                } else {
                    // the names on their baselines, then the title on its own: the lower rule runs under the title
                    let n = Composer.bylineLines(a.author.trimmed, width: by.width).count
                    let title = HouseStyle.font("MyriadPro-It", 10)
                    let split = min(by.maxY, by.minY + 14.8 + CGFloat(n) * HouseStyle.bylineLeading - title.ascender)
                    elements.append(.frame(Frame(type: .author, box: rel(CGRect(x: by.minX, y: by.minY, width: by.width, height: split - by.minY)), link: letter)))
                    elements.append(.frame(Frame(type: .authorTitle, box: rel(CGRect(x: by.minX, y: split, width: by.width, height: by.maxY - split)), link: letter)))
                }
            }
            if f.maxY - g.bodyTop > HouseStyle.leading {
                elements.append(.frame(Frame(type: .body, box: rel(CGRect(x: f.minX, y: g.bodyTop, width: f.width, height: f.maxY - g.bodyTop)), link: letter)))
            }
        }

        // pictures, pull quotes and ads. A story's one photo or pull quote shares its story's letter (dropping
        // another story fills them too); a second photo of a story, or a picture of a story not in the selection,
        // takes its own fill
        let photosPerStory = Dictionary(insetList.filter { $0.kind == .photo }.compactMap(\.article).map { ($0, 1) }, uniquingKeysWith: +)
        var storyFills: [String: Fill] = [:]
        for (id, letter) in letters { storyFills[letter] = Fill(link: letter, article: id) }
        for i in insetList {
            guard let g = obs.geoms[i.id] else { continue }
            switch i.kind {
            case .photo:
                guard let aid = i.article, articles[aid] != nil else { continue }
                let shared = letters[aid].flatMap { photosPerStory[aid] == 1 ? $0 : nil }
                let image = Frame(type: .image, box: rel(g.picture), link: shared)
                elements.append(.frame(image))
                var caption: Frame?
                if let tr = g.textRect {
                    caption = Frame(type: .caption, box: rel(tr.insetBy(dx: 0, dy: -2)), link: shared)
                    elements.append(.frame(caption!))
                }
                if let letter = shared {
                    storyFills[letter]?.photo = i.photo
                    storyFills[letter]?.focusX = i.focusX; storyFills[letter]?.focusY = i.focusY
                } else {
                    var fi = Fill(frame: image.id, article: aid, photo: i.photo)
                    fi.focusX = i.focusX; fi.focusY = i.focusY
                    fills.append(fi)
                    if let c = caption { fills.append(Fill(frame: c.id, article: aid, photo: i.photo)) }
                }
            case .pullQuote:
                guard let aid = i.article, articles[aid] != nil else { continue }
                let q = Frame(type: .pullQuote, box: rel(g.picture), link: letters[aid])
                elements.append(.frame(q))
                if letters[aid] == nil { fills.append(Fill(frame: q.id, article: aid)) }
            case .extra:
                guard let eid = i.extra, extras[eid] != nil else { continue }
                let ad = Frame(type: .ad, box: rel(g.picture))
                elements.append(.frame(ad))
                fills.append(Fill(frame: ad.id, extra: eid))
                if let tr = g.textRect {
                    let c = Frame(type: .caption, box: rel(tr.insetBy(dx: 0, dy: -2)))
                    elements.append(.frame(c))
                    fills.append(Fill(frame: c.id, extra: eid))
                }
            }
        }
        fills.append(contentsOf: storyFills.values.sorted { ($0.link ?? "") < ($1.link ?? "") })
        guard !elements.isEmpty else { return nil }

        // the page's columns the box lies across, at the page's widths: a body frame sets in the columns its block did
        let grid = layout.grid
        let spanned = (0..<grid.columns).filter { k in
            let x0 = grid.x(k), x1 = x0 + grid.colWidth
            return x0 < bounds.maxX - 1 && x1 > bounds.minX + 1
        }.count
        let version = ComponentVersion(number: 1, width: bounds.width, height: bounds.height, columns: max(1, spanned), elements: elements)
        let component = Component(name: name, versions: [version])
        var taken = Set<LayoutSelection>()
        for b in blocks { taken.insert(.block(b.id)) }
        for i in insetList { taken.insert(.inset(i.id)) }
        return (page, ComponentPlan(component: component, origin: origin, fills: fills, taken: taken))
    }

    /// Make Component… on a selection: each item becomes typed frames of a new component (a story block its
    /// kicker, headline, author, author title and body frames linked as one story; a photo image and caption
    /// frames; a pull quote a pull-quote frame; an ad an ad frame), saved with its frames empty and placed where
    /// the items were, filled with them, so the page sets as it did; the items come off the page. One undo step,
    /// then the in-place editor opens on it. Nil, and nothing changes, when the selection holds nothing that can
    /// become a frame (a placed component alone, say).
    @discardableResult
    func makeComponent(from selection: Set<LayoutSelection>, name: String) -> PlacedComponent.ID? {
        guard let (page, plan) = planComponent(from: selection, name: name) else { return nil }
        if pointer.isActive { pointerCancelled() }
        var placed: PlacedComponent.ID?
        edit("Make Component") {
            removeAll(plan.taken)
            placed = issue.place(plan.component, version: 1, on: page, at: plan.origin, fills: plan.fills)
        }
        guard let placed else { return nil }
        select([])
        focusedPage = page
        enterInPlace(placed)
        return placed
    }
}
