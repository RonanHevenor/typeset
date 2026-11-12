import AppKit

// How the composer draws placed components. Shapes, text, art and most frames are drawn here, element by
// element in the order they're kept. Body and whole-story frames aren't: they become story blocks for the page
// (`componentBlocks`), set with the same code as any story module, in the component's own columns, so copyfit
// and jumps work there too.

extension Composer {
    /// A body or whole-story frame on a page, as a story block the page sets along with its own.
    struct ComponentBlock {
        var block: StoryBlock
        var bodyOnly: Bool             // a body frame: no kicker, headline or byline
        var gutter: CGFloat
        var placed: PlacedComponent.ID
        var frame: Frame.ID
        /// What the body keeps clear of inside its own component: the image, ad and pull-quote frames (padded as
        /// pictures on the page are), a caption that draws, and the byline frames of its own story (phase 7, Make
        /// Component: a block's body set in a frame wraps as the block's did).
        var ownAvoid: [CGRect] = []
    }

    /// What a body frame's text keeps clear of among the other frames of its component.
    func ownAvoid(for f: Frame, of rc: ResolvedComponent, articles: [Article.ID: Article]) -> [CGRect] {
        var out: [CGRect] = []
        let article = rc.placed.fill(for: f)?.article.flatMap { articles[$0] }
        for g in rc.version.frames where g.id != f.id {
            let r = rc.rect(g.box)
            switch g.type {
            case .image, .ad, .pullQuote:
                out.append(Self.wrap(r))
            case .caption:
                // a caption frame's box is its text's rect with 2 pt of air above and below (as the page draws a
                // caption), so it's padded 8 below its box: 10 below the text, as on the page
                if captionDraws(g, of: rc, articles: articles) { out.append(CGRect(x: r.minX - HouseStyle.gutter, y: r.minY - 8, width: r.width + 2 * HouseStyle.gutter, height: r.height + 8 + 8)) }
            case .author, .authorTitle:
                // the byline keeps 4 pt under its lower rule, as a block's does
                guard let l = f.link, g.link == l, let a = article, !a.author.trimmed.isEmpty else { continue }
                out.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 4))
            default:
                continue
            }
        }
        return out
    }

    /// Whether a caption frame draws any text: it's filled with an ad, or with a story whose photo has a caption.
    func captionDraws(_ g: Frame, of rc: ResolvedComponent, articles: [Article.ID: Article]) -> Bool {
        guard let fill = rc.placed.fill(for: g) else { return false }
        if fill.extra != nil { return true }
        guard let a = fill.article.flatMap({ articles[$0] }), let p = a.photos.first(where: { $0.id == fill.photo }) ?? a.photos.first else { return false }
        return Self.caption(p, width: rc.rect(g.box).width) != nil
    }

    /// Where a story set in a component's frames starts: the top of its kicker, headline or byline frames, and its
    /// body frame's top, which is fixed. A neighbour's byline lines up with it as with a block's.
    struct StoryHead { var top: CGFloat; var bodyTop: CGFloat; var article: Article.ID }

    /// A placed component that sets a story (it has a body or whole-story frame) keeps the page's stories clear of
    /// it as a story block does, not as a picture (phase 7: a block made into a component sets the page as it
    /// did): what's in the page's wrap is its pictures alone, each padded as a picture on the page is (an image or
    /// ad with the caption under it, a pull quote); a block that overlaps it keeps clear of it as of a block on
    /// it (`avoid(for:on:)`). Nil for any other component: it's an obstacle as its whole frame, like a picture.
    func storyShape(_ p: PlacedComponent, articles: [Article.ID: Article]) -> (pictures: [CGRect], art: [CGRect], heads: [StoryHead])? {
        guard let issue = componentSource, let rc = ResolvedComponent(p, in: issue, pageColumns: issue.layout?.columns ?? 3) else { return nil }
        let frames = rc.version.frames
        guard frames.contains(where: { $0.type.setsAsBlock }) else { return nil }
        let captions = frames.filter { $0.type == .caption && captionDraws($0, of: rc, articles: articles) }.map { rc.rect($0.box).insetBy(dx: 0, dy: 2) }
        var used = Set<Int>()
        var art: [CGRect] = []
        for g in frames where [.image, .ad, .pullQuote].contains(g.type) {
            var r = rc.rect(g.box)
            if g.type != .pullQuote {
                // its caption: the one hanging just under it, across it
                for (k, c) in captions.enumerated() where !used.contains(k) && c.minY >= r.maxY - 1 && c.minY - r.maxY <= 12 && c.minX < r.maxX && c.maxX > r.minX {
                    r = r.union(c); used.insert(k)
                }
            }
            art.append(r)
        }
        for (k, c) in captions.enumerated() where !used.contains(k) { art.append(c) }
        var heads: [StoryHead] = []
        for b in frames where b.type == .body {
            guard let l = b.link, let id = p.fill(for: b)?.article, articles[id] != nil else { continue }
            let head = frames.filter { $0.link == l && [.kicker, .headline, .author, .authorTitle].contains($0.type) }.map { rc.rect($0.box).minY }
            guard let top = head.min() else { continue }
            heads.append(StoryHead(top: top, bodyTop: rc.rect(b.box).minY, article: id))
        }
        return (art.map(Self.wrap), art, heads)
    }

    /// One id for a frame on a placed component, the same on every compose, so the fit and page caches hold.
    static func blockID(placed: PlacedComponent.ID, frame: Frame.ID) -> StoryBlock.ID {
        var u = placed.uuid, f = frame.uuid
        withUnsafeMutableBytes(of: &u) { a in withUnsafeBytes(of: &f) { b in for i in 0..<16 { a[i] ^= b[i] } } }
        return UUID(uuid: u)
    }

    func headlineSize(_ f: Frame, of rc: ResolvedComponent) -> CGFloat {
        f.size ?? HouseStyle.headlineSize(columns: rc.columnsSpanned(by: f.box))
    }

    /// A headline frame's text set as a block sets its headline (a flow of lines, wrapping round its component's
    /// pictures as display type does), so a block made into frames keeps its headline's lines where they were.
    /// Drawn with its container's origin at the frame's corner.
    func setHeadline(_ f: Frame, of rc: ResolvedComponent, _ text: NSAttributedString) -> (storage: NSTextStorage, manager: NSLayoutManager, container: FlowContainer, used: CGFloat)? {
        let r = rc.rect(f.box)
        let display = rc.version.frames.filter { [.image, .ad, .pullQuote].contains($0.type) }.map { Self.wrap(rc.rect($0.box)) }
            .map { CGRect(x: $0.minX, y: $0.minY + 8 - Self.displayClearance, width: $0.width,
                          height: max(1, $0.height - (Self.clearAbovePicture - Self.displayClearance) - (Self.clearBelowPicture - Self.displayClearance))) }
            .filter { $0.intersects(r) }
        // the frame's box holds the lines' ink (what the block used); the last line's fragment runs its leading below it
        let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        return setHeadline(text, frame: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + ceil(font?.leading ?? 0) + 1), avoid: display)
    }

    /// The stories set in a page's components, as blocks for `storyRules` (phase 7): each body frame with its
    /// story's kicker, headline and byline frames is the block it was made from, its ink top where its kicker's or
    /// headline's capitals are, so the hairlines between it and the stories round it run as they did. With the
    /// pictures in those components, which the rules keep off as they keep off the page's.
    func ruleBlocks(on page: PageLayout, _ cp: ComposedPage, issue: Issue, articles: [Article.ID: Article]) -> (blocks: [StoryBlock], results: [StoryBlock.ID: BlockResult], art: [CGRect]) {
        var blocks: [StoryBlock] = [], results: [StoryBlock.ID: BlockResult] = [:], art: [CGRect] = []
        guard let layout = issue.layout else { return ([], [:], []) }
        for p in page.components {
            guard let rc = ResolvedComponent(p, in: issue, pageColumns: layout.columns), let shape = storyShape(p, articles: articles) else { continue }
            art += shape.art
            for b in rc.version.frames where b.type == .body {
                guard let l = b.link, var result = cp.componentBlockResults[p.id]?[b.id], let id = p.fill(for: b)?.article, let a = articles[id] else { continue }
                let body = rc.rect(b.box)
                let head = rc.version.frames.filter { $0.link == l && [.kicker, .headline, .author, .authorTitle].contains($0.type) }
                var frame = body
                for h in head { frame = frame.union(CGRect(x: body.minX, y: rc.rect(h.box).minY, width: body.width, height: 1)) }
                if let k = head.first(where: { $0.type == .kicker }), !a.kicker.trimmed.isEmpty {
                    result.inkTop = rc.rect(k.box).minY + 9.5 - HouseStyle.font(HouseStyle.kickerFace, HouseStyle.kickerSize).capHeight
                } else if let hf = head.first(where: { $0.type == .headline }), !a.plainHeadline.trimmed.isEmpty,
                          let h = setHeadline(hf, of: rc, Self.headline(markup: a.headline.trimmed, size: headlineSize(hf, of: rc))), h.storage.length > 0 {
                    let frag = h.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    let font = (h.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? HouseStyle.font(HouseStyle.headlineFace, headlineSize(hf, of: rc))
                    result.inkTop = rc.rect(hf.box).minY + frag.minY + h.manager.location(forGlyphAt: 0).y - font.capHeight
                } else if let by = head.first(where: { $0.type == .author }), !a.author.trimmed.isEmpty {
                    result.inkTop = rc.rect(by.box).minY
                }
                // the block began at or over its display type, which may have been held down to meet a neighbour's
                // byline: up to the component's top, or a module's gap under whatever of the component lies over it
                let others = rc.version.elements.filter { $0.frame?.link != l }.map { rc.rect($0.box) }
                    .filter { $0.maxY <= frame.minY + 0.5 && $0.minX < frame.maxX && $0.maxX > frame.minX }
                let top = max(rc.frame.minY, others.map { $0.maxY + HouseStyle.moduleGap }.max() ?? rc.frame.minY)
                if top < frame.minY { frame = frame.union(CGRect(x: frame.minX, y: top, width: frame.width, height: 1)) }
                let block = StoryBlock(id: Self.blockID(placed: p.id, frame: b.id), article: id, frame: Box(frame), columns: 1, headlineSize: 0)
                blocks.append(block)
                results[block.id] = result
            }
        }
        return (blocks, results, art)
    }

    /// How many of the page's columns a rect is, when it starts on a column's edge and ends on another's.
    static func pageColumns(of r: CGRect, grid: Grid) -> Int? {
        for k in stride(from: grid.columns, through: 1, by: -1) where abs(grid.span(k) - r.width) < 0.5 {
            if (0...(grid.columns - k)).contains(where: { abs(grid.x($0) - r.minX) < 0.5 }) { return k }
        }
        return nil
    }

    func componentBlocks(on page: PageLayout, issue: Issue, pageColumns: Int, articles: [Article.ID: Article]) -> [ComponentBlock] {
        var out: [ComponentBlock] = []
        for p in page.components {
            guard let rc = ResolvedComponent(p, in: issue, pageColumns: pageColumns) else { continue }
            for f in rc.version.frames where f.type.setsAsBlock {
                guard let id = p.fill(for: f)?.article, articles[id] != nil else { continue }
                let r = rc.rect(f.box)
                guard r.width > 20, r.height > HouseStyle.leading else { continue }
                // a frame lying exactly on the page's columns sets in them, though the component's own columns are
                // narrower (one made from items that don't end on a column edge); else in the component's
                let n = issue.layout.flatMap { Self.pageColumns(of: r, grid: $0.grid) } ?? rc.columnsSpanned(by: f.box)
                let block = StoryBlock(id: Self.blockID(placed: p.id, frame: f.id), article: id, frame: Box(r), columns: n,
                                       headlineSize: f.size ?? HouseStyle.headlineSize(columns: n))
                // the frame's own share of the columns can be narrower than the component: its gutter fits it too
                let gutter = ComponentVersion.clampedGutter(rc.gutter, width: r.width, columns: n)
                out.append(ComponentBlock(block: block, bodyOnly: f.type == .body, gutter: gutter, placed: p.id, frame: f.id,
                                          ownAvoid: ownAvoid(for: f, of: rc, articles: articles)))
            }
        }
        return out
    }

    /// What a story set inside a component keeps clear of: the page's pictures, the components lying on top
    /// of its own (placed after it), and its own component's picture and byline frames (`ownAvoid`). Not its
    /// own component's box, and not one underneath it, such as a background panel.
    func avoid(forComponentBlock b: ComponentBlock, _ obs: Obstacles) -> [CGRect] {
        guard let z = obs.componentOrder.firstIndex(of: b.placed) else { return obs.wrap + b.ownAvoid }
        return obs.pictures + obs.componentOrder.dropFirst(z + 1).compactMap { obs.components[$0] } + b.ownAvoid
    }

    /// The stories a page's components show in their story frames (headline, caption, image…), in order: what
    /// the page's desk counts besides its blocks.
    func componentStories(on page: PageLayout, issue: Issue, pageColumns: Int) -> [Article.ID] {
        var out: [Article.ID] = []
        for p in page.components {
            guard let rc = ResolvedComponent(p, in: issue, pageColumns: pageColumns) else { continue }
            for f in rc.version.frames where f.type.isStoryField {
                if let id = p.fill(for: f)?.article, !out.contains(id) { out.append(id) }
            }
        }
        return out
    }

    /// A placed component's embedded art, decoded once.
    func artImage(_ a: ArtElement) -> NSImage? {
        if let c = artImages[a.id], c.hash == ArtElement.sample(a.data) { return c.image }
        guard let img = NSImage(data: a.data) else { return nil }
        artImages[a.id] = (ArtElement.sample(a.data), img)
        return img
    }

    func drawComponents(_ page: PageLayout, issue: Issue, number: Int, pageColumns: Int, articles: [Article.ID: Article],
                        firstPage: [Article.ID: Int] = [:], into cp: ComposedPage) {
        let extras = Dictionary(issue.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in page.components {
            guard let rc = ResolvedComponent(p, in: issue, pageColumns: pageColumns) else { continue }
            cp.componentFrames[p.id] = rc.frame
            // the component's teaser headlines set together: one size and line count for the group
            let teasers = rc.version.frames.contains { $0.type == .teaserHeadline } ? teaserSetting(of: rc, articles: articles) : nil
            for e in rc.version.elements {
                switch e {
                case .line(let l):
                    cp.ops.append(.line(rc.point(l.from), rc.point(l.to), l.width, l.color.nsColor))
                case .rect(let s):
                    let r = rc.rect(s.box)
                    if let f = s.fill { cp.ops.append(.fill(r, f.nsColor)) }
                    if let k = s.stroke, s.strokeWidth > 0 { cp.ops.append(.frame(r, s.strokeWidth, k.nsColor)) }
                case .ellipse(let s):
                    let r = rc.rect(s.box)
                    let path = NSBezierPath(ovalIn: s.stroke != nil ? r.insetBy(dx: s.strokeWidth / 2, dy: s.strokeWidth / 2) : r)
                    cp.ops.append(.path(path, s.fill?.nsColor, s.stroke?.nsColor, s.strokeWidth))
                case .text(let t):
                    cp.ops.append(.text(t.attributed, rc.rect(t.box)))
                case .art(let a):
                    let r = rc.rect(a.box)
                    if let img = artImage(a) { cp.ops.append(.art(img, r)) } else { cp.ops.append(.missing(r)) }
                case .frame(let f):
                    drawFrame(f, of: rc, issue: issue, number: number, section: cp.section, articles: articles, extras: extras,
                              firstPage: firstPage, teasers: teasers, into: cp)
                }
            }
        }
    }

    /// One frame: an issue field filled for this page, or what was dropped on it. Body and whole-story frames
    /// are set as blocks instead. An empty frame leaves a placeholder op, which only the screen draws (phase 5).
    private func drawFrame(_ f: Frame, of rc: ResolvedComponent, issue: Issue, number: Int, section: String,
                           articles: [Article.ID: Article], extras: [Extra.ID: Extra], firstPage: [Article.ID: Int],
                           teasers: TeaserSetting?, into cp: ComposedPage) {
        let r = rc.rect(f.box)
        let fill = rc.placed.fill(for: f)
        let article = fill?.article.flatMap { articles[$0] }
        func photo() -> Photo? {
            guard let a = article else { return nil }
            return a.photos.first { $0.id == fill?.photo } ?? a.photos.first
        }
        func aligned(_ s: NSAttributedString, _ fallback: NSTextAlignment? = nil) -> NSAttributedString {
            guard let al = f.alignment?.ns ?? fallback, s.length > 0 else { return s }
            let m = NSMutableAttributedString(attributedString: s)
            let p = ((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.alignment = al
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            return m
        }
        /// One line of type on the frame's first baseline, placed as `label` places the paper's furniture.
        func field(_ text: String, face: String, size: CGFloat, color: NSColor, in r: CGRect) -> DrawOp {
            let align: Align
            switch f.alignment ?? .left { case .left: align = .left(r.minX); case .center: align = .center(r.midX); case .right: align = .right(r.maxX) }
            return Self.label(text, face: face, size: size, color: color, align, baseline: r.minY + HouseStyle.font(face, size).ascender, width: r.width)
        }
        func colored(_ s: NSAttributedString) -> NSAttributedString {
            guard let c = f.color, s.length > 0 else { return s }
            let m = NSMutableAttributedString(attributedString: s)
            m.addAttribute(.foregroundColor, value: c.nsColor, range: NSRange(location: 0, length: m.length))
            return m
        }
        // nothing dropped here (or what was dropped has gone from the issue): the screen shows the frame's placeholder
        let empty: Bool = {
            switch f.type {
            case .pageNumber, .volume, .edition, .desk, .date: return false
            case .ad: return fill?.extra.flatMap { extras[$0] } == nil
            case .image: return fill?.extra.flatMap { extras[$0] } == nil && photo() == nil
            case .caption: return fill?.extra.flatMap { extras[$0] } == nil && article == nil
            default: return article == nil
            }
        }()
        if empty { cp.ops.append(.placeholder(r, f.type)); return }
        switch f.type {
        case .pageNumber, .volume, .edition, .desk, .date:
            let text = Self.fieldText(f, issue: issue, number: number, section: section)
            guard !text.isEmpty else { return }
            cp.ops.append(field(text, face: f.face ?? Frame.fieldFace, size: f.size ?? 12, color: (f.color ?? .ink).nsColor, in: r))
        case .body, .wholeStory:
            break                                                    // set as a block with the page's stories
        case .headline:
            guard let a = article, !a.plainHeadline.trimmed.isEmpty else { return }
            if let h = setHeadline(f, of: rc, colored(aligned(Self.headline(markup: a.headline.trimmed, size: headlineSize(f, of: rc))))) {
                cp.ops.append(.flow(h.manager, h.container, r.origin))
                cp.keep.append(h.storage)
            }
        case .teaserHeadline:
            guard let a = article, let t = teasers else { return }
            cp.ops.append(.text(colored(aligned(Self.teaser(a.teaserHeadline, size: t.size, lineHeight: t.lineHeight))),
                                CGRect(x: r.minX, y: r.minY + t.drop, width: r.width, height: t.height)))
        case .teaserPage:
            // where the teased story runs, as the Header's bar says it over each teaser
            guard let a = article else { return }
            cp.ops.append(field(firstPage[a.id].map { "Page \($0)" } ?? "Inside", face: f.face ?? Frame.fieldFace, size: f.size ?? 12,
                                color: (f.color ?? .ink).nsColor, in: r))
        case .kicker:
            // as a block's kicker: the label on its baseline (phase 7, so a block made into frames draws as it did;
            // the short rule that once ran under it is gone, its space kept)
            guard let a = article, !a.kicker.trimmed.isEmpty else { return }
            let t = colored(Self.kicker(a.kicker.trimmed))
            let w = min(ceil(t.size().width) + 2, r.width)
            let kf = HouseStyle.font(HouseStyle.kickerFace, HouseStyle.kickerSize)
            let x: CGFloat
            switch f.alignment ?? .left { case .left: x = r.minX; case .center: x = r.midX - w / 2; case .right: x = r.maxX - w }
            cp.ops.append(.text(t, CGRect(x: x, y: r.minY + 9.5 - kf.ascender, width: w, height: ceil(kf.ascender - kf.descender) + 2)))
        case .author:
            // as a block's byline: a rule, the names in red on the house baseline, the lower rule under the author
            // title when a linked author-title frame carries one, else under the names
            guard let a = article, !a.author.trimmed.isEmpty else { return }
            let ink = (f.color ?? .ink).nsColor
            cp.ops.append(.line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), 0.5, ink))
            let align: Align
            switch f.alignment ?? .left { case .left: align = .left(r.minX); case .center: align = .center(r.midX); case .right: align = .right(r.maxX) }
            var baseline = r.minY + 14.8
            for line in Self.bylineLines(a.author.trimmed, width: r.width) {
                cp.ops.append(Self.label(line, face: "Raleway-SemiBold", size: f.size ?? 12, color: (f.color ?? Paint(HouseStyle.bylineRed)).nsColor, align, baseline: baseline, width: r.width))
                baseline += HouseStyle.bylineLeading
            }
            var bottom = r.maxY
            if let l = f.link, !a.authorTitle.trimmed.isEmpty,
               let title = rc.version.frames.first(where: { $0.type == .authorTitle && $0.link == l }) {
                bottom = max(bottom, rc.rect(title.box).maxY)
            }
            cp.ops.append(.line(CGPoint(x: r.minX, y: bottom), CGPoint(x: r.maxX, y: bottom), 0.5, ink))
        case .authorTitle:
            guard let a = article, !a.authorTitle.trimmed.isEmpty else { return }
            cp.ops.append(field(a.authorTitle.trimmed, face: "MyriadPro-It", size: f.size ?? 10, color: (f.color ?? .ink).nsColor, in: r))
        case .pullQuote:
            guard let a = article, !a.pullQuote.trimmed.isEmpty else { return }
            let pad: CGFloat = 10
            cp.ops.append(.frame(r, HouseStyle.pullQuoteRule, (f.color ?? .ink).nsColor))
            // the text sits 2 pt higher than its padding, as a pull quote on the page does
            cp.ops.append(.text(colored(aligned(Self.pullQuote(a.pullQuote.trimmed, width: r.width))), r.insetBy(dx: pad, dy: pad - 2)))
        case .caption:
            if let e = fill?.extra.flatMap({ extras[$0] }) {
                // an ad's caption, when an ad frame's caption frame is filled with the same ad
                guard let c = Self.caption(Photo(path: e.path, caption: e.caption, credit: e.credit), width: r.width) else { return }
                cp.ops.append(.text(colored(aligned(c)), r))
                return
            }
            guard let ph = photo(), let c = Self.caption(ph, width: r.width) else { return }
            cp.ops.append(.text(colored(aligned(c)), r))
        case .credit:
            guard let ph = photo(), let c = Self.caption(Photo(path: "", caption: "", credit: ph.credit), width: r.width) else { return }
            cp.ops.append(.text(colored(aligned(c)), r))
        case .image:
            if let e = fill?.extra.flatMap({ extras[$0] }) {
                // an ad or graphic dropped on an image frame fills it and crops like a photo
                if let img = image(e.path) { cp.ops.append(.image(img, r, HouseStyle.photoOutline, fill?.focus ?? CGPoint(x: 0.5, y: 0.5))) } else { cp.ops.append(.missing(r)) }
                return
            }
            guard let ph = photo() else { return }
            if let img = image(ph.path) {
                cp.ops.append(.image(img, r, HouseStyle.photoOutline, fill?.focus ?? CGPoint(x: 0.5, y: 0.5)))
            } else {
                cp.ops.append(.missing(r))
            }
        case .ad:
            guard let e = fill?.extra.flatMap({ extras[$0] }) else { return }
            if let img = image(e.path) {
                // every picture has the house hairline: an ad's goes round the ad as fitted in its frame
                cp.ops.append(.fitted(img, r))
                cp.ops.append(.frame(Self.fitted(img.size, in: r), HouseStyle.photoOutline, HouseStyle.ink))
            } else { cp.ops.append(.missing(r)) }
        }
    }
}
