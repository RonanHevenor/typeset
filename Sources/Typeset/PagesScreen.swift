import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Step three: the generated paper, laid out on a canvas you edit directly. Story blocks, pictures and pull quotes
/// move, resize and travel between pages; text reflows as you go. The inspector lists where every story stands.
struct PagesScreen: View {
    @Environment(IssueStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        let pages = store.displayPages
        NavigationSplitView {
            PageNavigator(pages: pages)
                .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
        } detail: {
            if pages.isEmpty {
                ContentUnavailableView {
                    Label("No Paper Yet", systemImage: "newspaper")
                } description: {
                    Text("Generate the paper from the stories in priority order.")
                } actions: {
                    Button("Generate Paper") { store.generate() }.prominent()
                }
            } else {
                PageCanvas(pages: pages)
            }
        }
        .inspector(isPresented: $store.showInspector) {
            Group {
                if let ip = store.inPlace { InPlaceInspector(edit: ip) } else { LayoutInspector(pages: pages) }
            }
            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .onDisappear { store.leaveInPlace() }               // another step, or another issue: the edits are kept
        .onChange(of: store.issue.layout) { _, _ in store.followInPlace() }   // a menu command moved or removed it
        .onAppear { store.undoManager = undoManager }
        .onChange(of: undoManager) { _, u in store.undoManager = u }
    }
}

// MARK: - Page thumbnails

struct PageNavigator: View {
    @Environment(IssueStore.self) private var store
    let pages: [ComposedPage]

    var body: some View {
        List(selection: Binding(get: { store.focusedPage }, set: { store.focusedPage = $0 })) {
            ForEach(pages.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    PageRenderView(page: pages[i])
                        .frame(width: 104, height: 104 * HouseStyle.page.height / HouseStyle.page.width)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .overlay(alignment: .topTrailing) {
                            if pages[i].hasProblems {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .red)
                                    .offset(x: 5, y: -5)
                                    .help(pages[i].oversets.isEmpty ? "Empty space on this page" : "Text doesn't fit on this page")
                            }
                        }
                    Text(pages[i].isFront ? "Front" : "\(i + 1)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .tag(i)
                .contextMenu {
                    if store.isEditingTemplate { TemplatePageMenu(index: i, count: pages.count) } else {
                    if !pages[i].isFront { Button("Shuffle Page") { store.shufflePage(i) } }
                    if !pages[i].holes.isEmpty { Button("Fill Holes") { store.fillHoles(on: i) } }
                    Button("Add Page After") { store.addPage(after: i) }
                    Divider()
                    Button("Clear Page") { store.clearPage(i) }
                    if !pages[i].isFront, pages.count > 1 {
                        Button("Remove Page", role: .destructive) { store.removePage(i) }
                    }
                    }
                }
            }
            .onMove(perform: store.isEditingTemplate ? { from, to in
                if let f = from.first { store.movePage(f, to: f < to ? to - 1 : to) }      // the template editor reorders pages
            } : nil)
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Canvas

struct PageCanvas: View {
    @Environment(IssueStore.self) private var store
    let pages: [ComposedPage]
    /// What the pages' pointer views share (the hovered item, the page views); no drag state: that's the store's.
    @State private var pointerUI = CanvasPointerUI()
    @State private var pinchBase: CGFloat?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 34) {
                        ForEach(pages.indices, id: \.self) { i in
                            PageCard(index: i, page: pages[i])
                                .id(i)
                                .zIndex(store.pointer.isDragging && store.pointer.page == i ? 1 : 0)
                        }
                        Button { store.addPage() } label: {
                            Label("Add Page", systemImage: "plus")
                                .frame(width: HouseStyle.page.width * store.zoom, height: 80)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4])).foregroundStyle(.tertiary))
                    }
                    .padding(.vertical, 36)
                    .padding(.horizontal, 40)
                    .frame(minWidth: geo.size.width)
                }
                .onAppear { store.canvasViewport = geo.size; pointerUI.canvasMaxX = geo.frame(in: .global).maxX }
                .onChange(of: geo.size) { _, n in store.canvasViewport = n }
                .onChange(of: geo.frame(in: .global).maxX) { _, x in pointerUI.canvasMaxX = x }
                .onChange(of: store.focusedPage) { _, p in
                    // a click or a drop on a page makes it the focused page, but the canvas stays put (IB-2)
                    guard let p, !store.pointer.isActive, pointerUI.shouldScroll(to: p) else { return }
                    withAnimation(.snappy) { proxy.scrollTo(p, anchor: .top) }
                }
                .onAppear {
                    if let p = store.focusedPage, p > 0 { proxy.scrollTo(p, anchor: .top) }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: store.canvasSelection) { _, sel in
            if sel != nil { focused = true }                // Delete and the arrow keys act on the selection
            pointerUI.refresh(store)
        }
        // the pointer may be still while what's under it moves: a nudge, a zoom, an undo (IB-8)
        // a zoom moves the page under a still mouse: read where the mouse is once the pages are laid out again
        .onChange(of: store.zoom) { _, _ in DispatchQueue.main.async { pointerUI.rehoverAtMouse() } }
        .onChange(of: store.issue.layout) { _, _ in if !store.pointer.isActive { pointerUI.refresh(store) } }
        .environment(pointerUI)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    let base = pinchBase ?? store.zoom
                    pinchBase = base
                    store.zoom = (base * v.magnification).clamped(0.25, 2)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onDeleteCommand { store.deleteSelection() }
        .onExitCommand {
            // Escape mid-gesture drops it where it is; otherwise it clears the selection
            if store.pointer.isActive { store.pointerCancelled() } else if store.inPlace != nil { store.leaveInPlace() } else { store.select([]) }
        }
        .onMoveCommand { dir in
            let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
            switch dir {
            case .left: store.nudge(dx: -step, dy: 0)
            case .right: store.nudge(dx: step, dy: 0)
            case .up: store.nudge(dx: 0, dy: -step)
            case .down: store.nudge(dx: 0, dy: step)
            @unknown default: break
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let ip = store.inPlace { InPlaceBar(edit: ip) } else if store.layoutIsStale { StaleBanner() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { CanvasStatusBar(pages: pages) }
    }
}

/// The paper at a glance: pages, problems, and how much the stories could still give up.
struct CanvasStatusBar: View {
    @Environment(IssueStore.self) private var store
    let pages: [ComposedPage]

    var body: some View {
        let overset = pages.reduce(0) { $0 + $1.oversets.count }
        let online = pages.reduce(0) { $0 + $1.online.count }
        let blank = pages.reduce(0) { $0 + $1.blanks.reduce(0) { $0 + $1.lines } }
        let empty = pages.reduce(0.0) { $0 + $1.emptyArea }
        let room = store.fits.values.reduce(0.0) { $0 + $1.spare }
        let hard = store.fits.values.filter { abs($0.level) > Fit.comfortable + 0.001 && $0.overset == 0 }.count
        HStack(spacing: 14) {
            Text("\(pages.count) pages")
            if overset == 0, blank == 0, empty < 0.05 {
                Label("No problems", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                if overset > 0 { Label("\(overset) overset", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                if blank > 0 { Label("\(blank) blank lines", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                if empty >= 0.05 { Label(String(format: "%.1f in² empty", empty), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
            }
            if online > 0 {
                Label(online == 1 ? "1 story continues online" : "\(online) stories continue online", systemImage: "arrow.up.right.circle.fill")
                    .foregroundStyle(.orange)
                    .help("The story didn't finish in print, even set as tight as allowed: its last block ends \"\(HouseStyle.onlineLine)\"")
            }
            if hard > 0 {
                Label(hard == 1 ? "1 story set hard" : "\(hard) stories set hard", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Set past the comfortable range to fit; readers may notice. Give the story more or less room, or art, to bring it back.")
            }
            Spacer()
            Text(String(format: "stories can give up %.0f in²", room)).foregroundStyle(.secondary)
            Text("\(Int((store.zoom * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                .help("Zoom: pinch, ⌘+ / ⌘−, ⌘0 to fit, ⌘1 for actual size")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct StaleBanner: View {
    @Environment(IssueStore.self) private var store
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Theme.nameplateRed)
            Text("Stories or their order changed since this paper was generated.")
            Button("Regenerate") { store.generate() }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 10)
    }
}

struct PageCard: View {
    @Environment(IssueStore.self) private var store
    let index: Int
    let page: ComposedPage

    var body: some View {
        let z = store.zoom
        let pad = CanvasHitTest.reach
        let shapes = Dictionary(store.hitItems(on: index).map { ($0.id, $0.shape) }, uniquingKeysWith: { a, _ in a })
        let size = CGSize(width: HouseStyle.page.width * z, height: HouseStyle.page.height * z)
        let layout = store.issue.layout?.pages[safe: index]
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                // while a component is edited in place, the paper is greyscale and faded (phase 7)
                PageRenderView(page: page, guides: store.showGuides, markers: true)
                    .frame(width: size.width, height: size.height)
                    .grayscale(store.inPlace != nil ? 1 : 0)
                    .opacity(store.inPlace != nil ? 0.45 : 1)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                // right-clicks fall through the pointer view to here; the menu is for what the hit test finds
                if store.inPlace == nil { PageMenuArea(index: index, size: size) }
                // the handles only draw: the page's pointer view takes every press and asks the hit test
                ForEach(layout?.stories ?? []) { block in
                    BlockHandle(pageIndex: index, block: block, result: page.blockResults[block.id])
                }
                ForEach(layout?.components ?? []) { c in
                    ComponentHandle(pageIndex: index, placed: c, frame: page.componentFrames[c.id] ?? c.frame.rect)
                        .zIndex(1)                                            // over the stories, under the pictures, as the hit test has it
                }
                ForEach(layout?.insets ?? []) { inset in
                    if let full = page.insetFrames[inset.id], let picture = page.pictureFrames[inset.id] {
                        InsetHandle(pageIndex: index, inset: inset, full: shapes[inset.id] ?? full, picture: picture)
                            .zIndex(2)                                            // pictures always sit over the blocks they're in
                    }
                }
                HoverOutline(index: index).zIndex(2.5)
                MultiSelectionOverlay(index: index).zIndex(2.6)
                if store.dropTarget == index, let p = store.dropPreview {
                    // from the inspector, or an item carried here from another page: the same dashed preview
                    let label = store.inspectorDrag.map { store.name(of: $0) } ?? store.pointer.item.map { store.name(of: $0) } ?? ""
                    DropPreview(rect: p, zoom: z, label: label).zIndex(3)
                }
                if let fb = store.fitBand, fb.page == index {
                    FitBandOverlay(band: fb.band, house: fb.house, zoom: z).zIndex(3)
                }
                if let g = store.activeGuides, g.page == index {
                    GuideOverlay(guides: g.guides, zoom: z).zIndex(3)
                }
                PageDropTarget(index: index, pad: pad)
                    .frame(width: size.width + 2 * pad, height: size.height + 2 * pad)
                    .offset(x: -pad, y: -pad)
                    .zIndex(4)                                                    // on top: every left press on the page is its
                if let ip = store.inPlace, store.placedComponent(ip.placed)?.page == index {
                    // the in-place editor: the component in full colour, taking every press on this page
                    InPlaceLayer(editor: ip.editor, zoom: z)
                        .frame(width: size.width, height: size.height)
                        .zIndex(5)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay {
                if store.dropTarget == index {
                    Rectangle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .onDrop(of: DragItem.types + [.fileURL], delegate: PageDropDelegate(store: store, index: index))
            caption(width: size.width)
        }
    }

    private func caption(width: CGFloat) -> some View {
        let layout = store.issue.layout?.pages[safe: index]
        let stories = Set(layout?.stories.map(\.article) ?? [])
        let fits = store.fits
        let spare = stories.reduce(0.0) { $0 + (fits[$1]?.spare ?? 0) }
        let short = stories.reduce(0.0) { $0 + (fits[$1]?.short ?? 0) }
        let empty = (layout?.stories.isEmpty ?? true) && (layout?.insets.isEmpty ?? true)
        return HStack(spacing: 8) {
            Text(page.isFront ? "Front Page" : "Page \(index + 1)")
                .fontWeight(.semibold)
            if !page.section.isEmpty, !page.isFront {
                Text(page.section).foregroundStyle(.secondary)
            }
            if !page.online.isEmpty {
                Label("\(page.online.reduce(0) { $0 + $1.lines }) lines online", systemImage: "arrow.up.right.circle.fill")
                    .foregroundStyle(.orange)
                    .help(page.online.map { "\($0.story): \($0.lines) lines read on poly.rpi.edu" }.joined(separator: "\n"))
            }
            if !page.blanks.isEmpty {
                Label("\(page.blanks.reduce(0) { $0 + $1.lines }) blank lines", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(page.blanks.map { "\($0.story): \($0.lines) lines can't be filled, even set loose" }.joined(separator: "\n"))
            }
            if page.emptyArea > 0.05 {
                Label(String(format: "%.1f in² empty", page.emptyArea), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("Nothing covers this much of the page")
            }
            if short > 0.05 {
                Label(String(format: "needs %.1f in²", short), systemImage: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(.red)
                    .help("Even set as tight as allowed, the stories here need this much more room")
            } else if spare > 0.05 {
                Label(String(format: "room for %.1f in²", spare), systemImage: "square.dashed")
                    .foregroundStyle(.secondary)
                    .help("Set as tight as allowed, the stories here could give up this much: drop an ad or graphic in and they tighten")
            }
            Spacer()
            if !page.holes.isEmpty, !empty {
                Button { withAnimation(.snappy) { store.fillHoles(on: index) } } label: {
                    Label("Fill Holes", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .help("Run the story above each hole down into it; copyfitting loosens its text to fill")
            }
            if empty, !page.isFront, (store.issue.layout?.pages.count ?? 0) > 1 {
                Button { store.removePage(index) } label: { Label("Remove Page", systemImage: "minus.rectangle.portrait") }
                    .buttonStyle(.borderless)
            }
            if !page.isFront, !empty {
                Button { withAnimation(.snappy) { store.shufflePage(index) } } label: {
                    Label("Shuffle Page", systemImage: "dice")
                }
                .buttonStyle(.borderless)
                .help("Try another arrangement of this page's stories")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(width: width)
    }
}

/// While a block's edge is pulled: the band where it can land and the story still sets comfortably, and the line
/// where it would be set at house style (the edge snaps there).
struct FitBandOverlay: View {
    let band: CGRect
    let house: CGFloat
    let zoom: CGFloat

    var body: some View {
        let green = Color(red: 0.1, green: 0.6, blue: 0.3)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(green.opacity(0.14))
                .frame(width: band.width * zoom, height: max(1, band.height * zoom))
                .offset(x: band.minX * zoom, y: band.minY * zoom)
            Rectangle()
                .fill(green)
                .frame(width: band.width * zoom, height: 1.5)
                .offset(x: band.minX * zoom, y: house * zoom - 0.75)
            Text("fits")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(green, in: Capsule())
                .fixedSize()
                .offset(x: band.maxX * zoom + 6, y: house * zoom - 8)
        }
        .allowsHitTesting(false)
    }
}

/// Alignment lines while something is dragged.
struct GuideOverlay: View {
    let guides: [Guide]
    let zoom: CGFloat
    var body: some View {
        Canvas { ctx, size in
            for g in guides {
                var p = Path()
                switch g.axis {
                case .x: p.move(to: CGPoint(x: g.at * zoom, y: 0)); p.addLine(to: CGPoint(x: g.at * zoom, y: size.height))
                case .y: p.move(to: CGPoint(x: 0, y: g.at * zoom)); p.addLine(to: CGPoint(x: size.width, y: g.at * zoom))
                }
                ctx.stroke(p, with: .color(Color(nsColor: .controlAccentColor)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Story blocks

/// What's drawn over a story block: its outline and label when it's selected or being dragged, the edge the pointer
/// has hold of, the corner dots and the byline grip. It takes no clicks: the page's pointer view does, through
/// `CanvasHitTest` and the store's pointer state machine (click to select, drag to move with its pictures, pull an
/// edge to resize, double-click to fit, carry onto another page).
struct BlockHandle: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let block: StoryBlock
    let result: Composer.BlockResult?

    /// How far either side of an edge the pointer can be and still have hold of it, in screen points.
    static let reach: CGFloat = CanvasHitTest.reach

    var body: some View {
        let z = store.zoom
        let f = block.frame.rect
        let pad = Self.reach
        let size = CGSize(width: f.width * z, height: f.height * z)
        let selected = store.selectedBlock == block.id
        let pointer = store.pointer
        let mine = pointer.item == .block(block.id)
        let dragging = mine && pointer.isDragging
        let active = selected || dragging
        let accent = Color(nsColor: .controlAccentColor)
        // the edge in hand: the one being pulled or pressed, else the one the pointer is over
        let zone: ResizeZone? = mine && (pointer.phase == .resizing || pointer.phase == .pressed) ? pointer.hit?.edge
            : selected && !pointer.isActive ? store.hoverZone : nil
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(accent.opacity(dragging ? 0.06 : 0))
                .padding(pad)
            Rectangle()
                .strokeBorder(accent.opacity(active ? 1 : 0.55), lineWidth: active ? 1.5 : 1)
                .opacity(active ? 1 : 0)
                .padding(pad)
            if active {
                statusLabel.offset(x: pad, y: pad - 22)
            }
            if selected, !dragging {
                if let live = zone {
                    EdgeHighlight(zone: live, size: size).padding(pad)
                }
                if let by = result?.byline, block.columns > 1 {
                    // centred on the byline's right edge, where the hit test puts it
                    bylineGrip.position(x: pad + (by.maxX - f.minX) * z, y: pad + (by.midY - f.minY) * z)
                }
                ForEach(ResizeZone.allCases, id: \.self) { c in
                    handleDot.position(x: pad + c.unit.x * size.width, y: pad + c.unit.y * size.height)
                }
            }
        }
        .frame(width: size.width + 2 * pad, height: size.height + 2 * pad, alignment: .topLeading)
        .offset(x: f.minX * z - pad, y: f.minY * z - pad)
        .allowsHitTesting(false)
    }

    /// The grip on the byline's right edge: drag it across the block's columns to widen a long shared byline.
    private var bylineGrip: some View {
        Capsule()
            .fill(.white)
            .overlay(Capsule().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1.5))
            .frame(width: 9, height: 22)
            .shadow(color: .black.opacity(0.25), radius: 1)
    }

    private var handleDot: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.25), radius: 1)
    }

    private var statusLabel: some View {
        let title = store.article(block.article)?.plainHeadline ?? "Story"
        var detail = "\(block.columns) col"
        var warn = false
        if let r = result {
            if r.oversetLines > 0 { detail += " · \(r.oversetLines) lines online"; warn = !r.online }
            else if r.empty > 0 { detail += " · \(r.empty) empty lines" }
        }
        // stacked stories keep the house gap between them; closer than that reads as one story
        if let others = store.issue.layout?.pages[safe: pageIndex]?.stories {
            let f = block.frame.rect
            for o in others where o.id != block.id && o.article != block.article {
                let g = o.frame.rect
                guard min(f.maxX, g.maxX) - max(f.minX, g.minX) > 40 else { continue }
                let gap = g.minY >= f.maxY ? g.minY - f.maxY : f.minY - g.maxY
                if gap >= 0, gap < HouseStyle.moduleGap - 2 {
                    detail += " · \(Int(gap.rounded())) pt from the story \(g.minY >= f.maxY ? "below" : "above"), house gap \(Int(HouseStyle.moduleGap))"
                    warn = true
                    break
                }
            }
        }
        if let r = result, r.oversetLines == 0, r.empty == 0, !warn { detail += " · fits" }
        return HStack(spacing: 6) {
            Text(title).lineLimit(2).frame(maxWidth: max(220, block.frame.w * store.zoom - 20), alignment: .leading).fixedSize(horizontal: true, vertical: false)
            Text(detail).opacity(0.85).fixedSize()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(warn ? Color.red : Color(nsColor: .controlAccentColor), in: Capsule())
        .fixedSize()
    }
}

/// The right-click menu for a story block.
struct BlockMenu: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let block: StoryBlock

    var body: some View {
        let pageCount = store.issue.layout?.pages.count ?? 0
        Menu("Columns") {
            ForEach(1...max(1, store.grid.columns), id: \.self) { n in
                Button(n == 1 ? "1 Column" : "\(n) Columns") { store.setColumns(n, block: block.id) }
            }
        }
        if block.columns > 1 {
            Menu("Byline Width") {
                ForEach(1...block.columns, id: \.self) { n in
                    Button((n == 1 ? "1 Column" : "\(n) Columns") + (block.bylineColumns == n ? "  ✓" : "")) { store.setBylineColumns(n, block: block.id) }
                }
            }
        }
        Menu("Headline Size") {
            ForEach([24, 30, 36, 44, 52] as [CGFloat], id: \.self) { s in
                Button("\(Int(s)) pt" + (block.headlineSize == s ? "  ✓" : "")) { store.setHeadlineSize(s, block: block.id) }
            }
        }
        Divider()
        Button("Fit Height to Text") { store.fitBlock(block.id) }
        Button("Fill Down") { store.fillDown(block.id) }
        Button("Fill Space") { withAnimation(.snappy) { store.fillSpace(block.id) } }
        if let a = store.article(block.article), !a.photos.isEmpty || !a.pullQuote.trimmed.isEmpty {
            let art = store.artPlacements()
            Divider()
            if !a.photos.isEmpty {
                Menu("Add Photo") {
                    ForEach(Array(a.photos.enumerated()), id: \.element.id) { i, p in
                        let placed = art.photos[p.id]
                        let name = p.caption.trimmed.isEmpty ? (i == 0 ? "Lead photo" : "Photo \(i + 1)") : String(p.caption.trimmed.prefix(44))
                        Button(placed.map { "\(name)  (now on p. \($0.page + 1))" } ?? name) {
                            store.placePhoto(p.id, of: a.id, on: pageIndex, in: block.id)
                        }
                    }
                }
            }
            if !a.pullQuote.trimmed.isEmpty {
                Button(art.quotes[a.id] == nil ? "Add Pull Quote" : "Move Pull Quote Here") {
                    store.placePullQuote(of: a.id, on: pageIndex, in: block.id)
                }
            }
        }
        Divider()
        Menu("Move to Page") {
            ForEach(0..<max(1, pageCount), id: \.self) { p in
                Button(p == 0 ? "Front Page" : "Page \(p + 1)") {
                    guard p != pageIndex, let free = store.freeSpace(on: p) else { return }
                    store.edit("Move Story") { store.moveBlock(block.id, from: pageIndex, to: p, frame: CGRect(origin: free.origin, size: block.frame.rect.size)) }
                }
                .disabled(p == pageIndex)
            }
        }
        Menu("Continue on Page") {
            ForEach(0..<max(1, pageCount), id: \.self) { p in
                Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.addBlock(block.article, on: p) }
            }
        }
        Divider()
        Button("Dismiss Story to Sidebar") { store.parkStory(block.article) }
        Button("Remove from Page", role: .destructive) { store.removeBlock(block.id) }
    }
}

// MARK: - Pictures and pull quotes

/// What's drawn over a picture or pull quote: its outline and label when selected, the edge in hand, the dots, the
/// crop hint, and while it's dragged a copy of the picture with a shadow. `full` is its hit shape (picture plus
/// caption; an ad's fitted picture), so the outline is what a click takes. It takes no clicks itself.
struct InsetHandle: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let inset: Inset
    let full: CGRect
    let picture: CGRect

    var body: some View {
        let z = store.zoom
        let pad = BlockHandle.reach
        let size = CGSize(width: full.width * z, height: full.height * z)
        let selected = store.selectedInset == inset.id
        let pointer = store.pointer
        let mine = pointer.item == .inset(inset.id)
        let dragging = mine && pointer.isDragging
        let cropping = mine && pointer.phase == .cropping
        let zone: ResizeZone? = mine && (pointer.phase == .resizing || pointer.phase == .pressed) ? pointer.hit?.edge
            : selected && !pointer.isActive ? store.hoverZone : nil
        ZStack(alignment: .topLeading) {
            if dragging, let img = store.picture(for: inset) {
                // drawn as the page draws it, so nothing changes on drop: a photo cropped to fill at its focus, an ad
                // or graphic fitted whole inside its frame
                let fitted = inset.kind == .extra, focus = inset.focus
                let copy = NSImage(size: picture.size, flipped: true) { r in
                    if fitted { ComposedPage.drawFitted(img, in: r) } else { ComposedPage.drawFilled(img, in: r, focus: focus) }
                    return true
                }
                Image(nsImage: copy)
                    .resizable()
                    .frame(width: picture.width * z, height: picture.height * z)
                .offset(x: pad + (picture.minX - full.minX) * z, y: pad + (picture.minY - full.minY) * z)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            }
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: selected || dragging ? 2 : 1.25)
                .opacity(selected || dragging ? 1 : 0)
                .padding(pad)
            if selected, !dragging {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .fixedSize()
                    .offset(x: pad, y: pad - 22)
                if let live = zone {
                    EdgeHighlight(zone: live, size: size).padding(pad)
                }
                if cropping || (inset.kind != .pullQuote && store.hoverZone == nil && NSEvent.modifierFlags.contains(.command)) {
                    // what the frame is hiding, and how to slide it
                    let hidden = store.hidden(in: inset)
                    let how = "⌘ drag"
                    Text(hidden.width > 0.5 ? "\(how) to slide the crop ◁ ▷" : hidden.height > 0.5 ? "\(how) to slide the crop △ ▽" : "Nothing cropped")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .fixedSize()
                        .position(x: pad + size.width / 2, y: pad + size.height / 2)
                }
                ForEach(handleZones, id: \.self) { c in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.2), radius: 1)
                        .position(x: pad + c.unit.x * size.width, y: pad + c.unit.y * size.height)
                }
            }
        }
        .frame(width: size.width + 2 * pad, height: size.height + 2 * pad, alignment: .topLeading)
        .offset(x: full.minX * z - pad, y: full.minY * z - pad)
        .allowsHitTesting(false)
    }

    private var label: String {
        let grid = store.grid
        let n = (1...grid.columns).first { abs(grid.span($0) - picture.width) < 1 }
        let kind = inset.kind == .pullQuote ? "Pull quote" : inset.kind == .extra ? (store.extra(inset.extra)?.kind.rawValue ?? "Item") : "Photo"
        let size = String(format: "%.1f in²", picture.width * picture.height / 5184)
        return (n.map { "\(kind) · \($0) col" } ?? kind) + " · " + size
    }

    /// A pull quote's height follows its text, so only its sides can be pulled.
    private var handleZones: [ResizeZone] {
        inset.kind == .pullQuote ? [.e, .w] : ResizeZone.allCases
    }
}

/// The right-click menu for a picture or pull quote.
struct InsetMenu: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let inset: Inset

    var body: some View {
        if inset.kind != .pullQuote {
            Menu("Width") {
                ForEach(1...max(1, store.grid.columns), id: \.self) { n in
                    Button(n == 1 ? "1 Column" : "\(n) Columns") { setColumns(n) }
                }
            }
        }
        if inset.kind != .pullQuote, inset.focus != CGPoint(x: 0.5, y: 0.5) {
            Button("Center the Crop") { store.edit("Center Crop") { store.setInsetFocus(inset.id, page: pageIndex, focus: CGPoint(x: 0.5, y: 0.5)) } }
        }
        Button("Remove from Page", role: .destructive) { store.removeInset(inset.id) }
    }

    private func setColumns(_ n: Int) {
        let grid = store.grid
        var r = inset.frame.rect
        let w = grid.span(n)
        r.size.height *= w / max(1, r.width)
        r.size.width = w
        store.edit("Change Width") {
            store.setInsetFrame(inset.id, page: pageIndex, frame: store.onPage(store.onLineGrid(inset, frame: store.snap(r), on: pageIndex)))
        }
    }
}

// MARK: - Inspector

/// Where every story stands and how tight it's set, the ads and graphics waiting to run, and the controls for
/// whatever is selected. Drag anything from here onto a page.
struct LayoutInspector: View {
    @Environment(IssueStore.self) private var store
    let pages: [ComposedPage]

    var body: some View {
        let status = store.storyStatus()
        let fits = store.fits
        let extraPages = store.extraPages()
        let parked = store.issue.articles.filter { a in a.body.contains { !$0.trimmed.isEmpty } && (status[a.id]?.pages.isEmpty ?? true) }
        List {
            if let dragging = store.dragging {
                Section {
                    let isBlock = { if case .block = dragging { true } else { false } }()
                    Label(isBlock ? "Drop here to put the story on hold" : "Drop here to take it off the page",
                          systemImage: isBlock ? "tray.and.arrow.down" : "photo.badge.arrow.down")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(store.dragOutside ? Color.white : Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(store.dragOutside ? Color.accentColor : Color.accentColor.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                        .animation(.snappy, value: store.dragOutside)
                }
            }
            if let sel = store.canvasSelection {
                Section("Selection") { selectionControls(sel) }
            } else if store.isMultiSelection {
                Section("Selection") { MultiSelectionControls() }
            }
            if !parked.isEmpty, !store.isEditingTemplate {
                Section {
                    ForEach(parked) { a in storyRow(a, status: nil, fit: nil) }
                } header: {
                    Label("On Hold", systemImage: "tray")
                } footer: {
                    Text("Not on any page. Drag one onto a page to place it.").foregroundStyle(.secondary)
                }
            }
            if !store.isEditingTemplate {                      // a template has only components
            Section {
                ForEach(store.issue.articles.filter { !parked.contains($0) }) { a in
                    storyRow(a, status: status[a.id], fit: fits[a.id])
                }
            } header: {
                Text("Stories")
            } footer: {
                Text("Drag a story, one of its photos or its pull quote onto a page. Tight and loose are how far each story is set from the house style; room is what it could still give up.")
                    .foregroundStyle(.secondary)
            }
            }
            if !store.issue.extras.isEmpty, !store.isEditingTemplate {
                Section {
                    ForEach(store.issue.extras) { e in
                        ExtraStatusRow(extra: e, pages: extraPages[e.id] ?? [])
                            .contentShape(Rectangle())
                            .overlay(RowDragSource(item: .extra(e.id), title: e.title.isEmpty ? e.kind.rawValue : e.title, image: store.composer.image(e.path)) {
                                if let p = extraPages[e.id]?.first, let inset = store.issue.layout?.pages[p - 1].insets.first(where: { $0.extra == e.id }) {
                                    store.canvasSelection = .inset(inset.id); store.focusedPage = p - 1
                                }
                            })
                            .contextMenu {
                                Menu("Place on Page") {
                                    ForEach(pages.indices, id: \.self) { p in
                                        Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.placeExtra(e.id, on: p) }
                                    }
                                }
                            }
                    }
                } header: {
                    Label("Ads & Graphics", systemImage: "rectangle.on.rectangle.angled")
                } footer: {
                    Text("Drag one onto a page; the stories there tighten to make room. Image and PDF files dropped here, or straight onto a page, come in too.").foregroundStyle(.secondary)
                }
            }
            ComponentsSection(pageCount: pages.count)
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "pdf"].contains($0.pathExtension.lowercased()) }
            for u in files { store.addExtra(u.pathExtension.lowercased() == "pdf" ? .ad : .image, file: u) }
            return !files.isEmpty
        }
    }

    private func storyRow(_ a: Article, status: IssueStore.StoryStatus?, fit: FitInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StoryStatusRow(article: a, status: status, fit: fit, estimate: store.estimatedArea(a))
                .contentShape(Rectangle())
                .overlay(RowDragSource(item: .story(a.id), title: a.plainHeadline) { store.jump(to: a.id, blocks: status?.blocks ?? []) })
                .contextMenu {
                    Menu(status?.pages.isEmpty == false ? "Continue on Page" : "Place on Page") {
                        ForEach(pages.indices, id: \.self) { p in
                            Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.addBlock(a.id, on: p) }
                        }
                    }
                    if status?.pages.isEmpty == false {
                        Button("Dismiss to Sidebar") { store.parkStory(a.id) }
                    }
                }
            if !a.photos.isEmpty || !a.pullQuote.trimmed.isEmpty {
                ArtChips(article: a, pageCount: pages.count)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private func selectionControls(_ sel: LayoutSelection) -> some View {
        switch sel {
        case .block(let id):
            if let (page, b) = store.block(id) {
                let r = pages[safe: page]?.blockResults[id]
                let fit = store.fits[b.article]
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.article(b.article)?.plainHeadline ?? "Story")
                        .font(Theme.headline(15))
                        .fixedSize(horizontal: false, vertical: true)
                    if let r {
                        let (text, warn) = blockStatus(r, article: store.article(b.article), store: store)
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(warn ? .red : .secondary)
                    }
                    if let fit { FitGauge(fit: fit) }
                    Picker("Columns", selection: Binding(get: { b.columns }, set: { store.setColumns($0, block: id) })) {
                        ForEach(1...max(1, store.grid.columns), id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Headline \(Int(b.headlineSize)) pt", value: Binding(get: { b.headlineSize }, set: { store.setHeadlineSize($0, block: id) }), in: 14...60, step: 2)
                        .font(.callout)
                    HStack {
                        Button("Fit to Text") { store.fitBlock(id) }
                            .help("Shrink or grow the block to the shortest height that holds its text")
                        Button("Fill Down") { store.fillDown(id) }
                            .help("Run the block down to whatever is below it")
                        Button("Fill Space") { withAnimation(.snappy) { store.fillSpace(id) } }
                            .help("Run the block down and take up what the text can't fill: the story's photo sized to the gap, its pull quote, then a bigger headline")
                    }
                    .controlSize(.small)
                    if let a = store.article(b.article), !a.photos.isEmpty || !a.pullQuote.trimmed.isEmpty {
                        let art = store.artPlacements()
                        HStack {
                            if a.photos.count == 1, let p = a.photos.first {
                                Button(art.photos[p.id] == nil ? "Add Photo" : "Bring Photo Here") { store.placePhoto(p.id, of: a.id, on: page, in: id) }
                            } else if !a.photos.isEmpty {
                                Menu("Add Photo") {
                                    ForEach(Array(a.photos.enumerated()), id: \.element.id) { i, p in
                                        let name = p.caption.trimmed.isEmpty ? (i == 0 ? "Lead photo" : "Photo \(i + 1)") : String(p.caption.trimmed.prefix(44))
                                        Button(art.photos[p.id].map { "\(name)  (now on p. \($0.page + 1))" } ?? name) { store.placePhoto(p.id, of: a.id, on: page, in: id) }
                                    }
                                }
                                .fixedSize()
                            }
                            if !a.pullQuote.trimmed.isEmpty {
                                Button(art.quotes[a.id] == nil ? "Add Pull Quote" : "Bring Quote Here") { store.placePullQuote(of: a.id, on: page, in: id) }
                            }
                        }
                        .controlSize(.small)
                    }
                    HStack {
                        Menu("Continue on Page") {
                            ForEach(pages.indices, id: \.self) { p in
                                Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.addBlock(b.article, on: p) }
                            }
                        }
                        .fixedSize()
                        .help("Add another block of this story on that page; the text runs on into it")
                        Button("Dismiss to Sidebar") { store.parkStory(b.article) }
                        Button("Remove from Page", role: .destructive) { store.removeBlock(id) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        case .inset(let id):
            if let page = store.issue.layout?.pages.firstIndex(where: { $0.insets.contains { $0.id == id } }),
               let inset = store.issue.layout?.pages[page].insets.first(where: { $0.id == id }) {
                let r = inset.frame.rect
                VStack(alignment: .leading, spacing: 10) {
                    Text(inset.kind == .pullQuote ? "Pull quote" : inset.kind == .extra ? (store.extra(inset.extra)?.kind.rawValue ?? "Item") : "Photo")
                        .font(.headline)
                    Text(inset.kind == .extra ? (store.extra(inset.extra)?.title ?? "") : (store.article(inset.article)?.plainHeadline ?? ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "%.1f × %.1f in · %.1f in²", r.width / 72, r.height / 72, r.width * r.height / 5184))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Remove from Page", role: .destructive) { store.removeInset(id) }
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        case .component(let id):
            ComponentSelectionControls(id: id)
        }
    }
}

/// What one block of a story is doing, for the inspector: full, short, overset, jumping, or never reached.
func blockStatus(_ r: Composer.BlockResult, article a: Article?, store: IssueStore) -> (String, Bool) {
    if r.oversetLines > 0 { return (r.online ? "\(r.oversetLines) lines continue at poly.rpi.edu" : "\(r.oversetLines) lines don't fit", !r.online) }
    if r.used == 0, r.start >= r.total, r.total > 0 {
        return ("Nothing left to run here: the story ended" + (r.continuedFrom.map { " on page \($0)" } ?? " earlier"), true)
    }
    var parts: [String] = []
    if r.jumped, let to = r.jumpTo {
        let toGo = a.map { store.composer.lineCount($0, start: r.end, continuedFrom: nil, width: store.grid.colWidth) } ?? 0
        parts.append(toGo > 0 ? "\(toGo) lines continue on page \(to)" : "Continues on page \(to)")
    } else if r.end >= r.total {
        parts.append(r.continuedFrom != nil ? "Ends here" : "Whole story")
    }
    parts.append(r.empty > 0 ? "\(r.empty) empty line" + (r.empty == 1 ? "" : "s") : "fills the block")
    return (parts.joined(separator: " · "), false)
}

/// How tight or loose a story is set, as a bar from tightest to loosest with the house style in the middle.
struct FitGauge: View {
    let fit: FitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                let lim = CGFloat(Fit.limit), c = CGFloat(Fit.comfortable)
                let x = w * (CGFloat(fit.level) + lim) / (2 * lim)
                let emergency = abs(fit.level) > Fit.comfortable + 0.001
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 6)
                    Capsule().fill(.secondary.opacity(0.35))                        // the comfortable range
                        .frame(width: w * c / lim, height: 6).offset(x: w * (lim - c) / (2 * lim))
                    Rectangle().fill(.secondary).frame(width: 1, height: 10).offset(x: w / 2)
                    Circle().fill(fit.overset > 0 || emergency ? Color.orange : fit.level < 0 ? Theme.nameplateRed : Color.accentColor)
                        .frame(width: 10, height: 10).offset(x: x - 5)
                }
                .frame(height: 10)
            }
            .frame(height: 10)
            .help("Tightest to loosest. The darker band is the range nobody notices; outside it is the emergency range, used only when the story can't fit otherwise.")
            HStack {
                Text(FitGauge.setting(fit)).font(.caption).foregroundStyle(fit.overset > 0 ? .orange : .secondary)
                Spacer()
                Text(String(format: "%.1f in²", fit.area)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            let more = FitGauge.details(fit)
            if !more.isEmpty {
                Text(more)
                    .font(.caption)
                    .foregroundStyle(fit.orphans > 0 ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How the story is set: tight or loose, and by how much.
    static func setting(_ f: FitInfo) -> String {
        let pct = abs(f.percent) * 100
        if f.overset > 0 { return "\(f.overset) line\(f.overset == 1 ? "" : "s") continue online" + (abs(f.uniform) < 0.001 && f.places == 0 ? " · house style" : "") }
        if f.places > 0 {
            let n = f.places, k = abs(f.localLines)
            let base = abs(f.uniform) < 0.001 ? "House style" : (f.uniform < 0 ? "Tight" : "Loose") + " overall"
            return base + " · \(n) place\(n == 1 ? "" : "s") \(f.localLines < 0 ? "tightened to lose" : "loosened to gain") \(k) line\(k == 1 ? "" : "s")"
        }
        let very = abs(f.level) > Fit.comfortable + 0.001 ? "Very " : ""
        if f.percent < -0.004 { return String(format: "%@ight %.1f%%", very.isEmpty ? "T" : very + "t", pct) }
        if f.percent > 0.004 { return String(format: "%@oose %.1f%%", very.isEmpty ? "L" : very + "l", pct) }
        return "House style"
    }

    /// What's left over: blank lines, what it could still give up, blocks it never reaches.
    static func details(_ f: FitInfo) -> String {
        var parts: [String] = []
        if f.blank > 0 { parts.append("\(f.blank) blank line" + (f.blank == 1 ? "" : "s")) }
        if f.overset == 0, f.spare > 0.05 { parts.append(String(format: "room for %.1f in²", f.spare)) }
        if f.orphans > 0 { parts.append("\(f.orphans) block" + (f.orphans == 1 ? "" : "s") + " it never reaches") }
        return parts.joined(separator: " · ")
    }

    static func describe(_ f: FitInfo) -> String {
        let more = details(f)
        return more.isEmpty ? setting(f) : setting(f) + " · " + more
    }
}

struct StoryStatusRow: View {
    let article: Article
    let status: IssueStore.StoryStatus?
    var fit: FitInfo? = nil
    var estimate: Double = 0

    var body: some View {
        let hasText = article.body.contains { !$0.trimmed.isEmpty }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.plainHeadline.isEmpty ? "Untitled story" : article.plainHeadline)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(hasText ? .primary : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status?.overset ?? 0 > 0 ? .orange : .secondary)
                if let fit {
                    Text(FitGauge.describe(fit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(fit.overset > 0 || abs(fit.level) > Fit.comfortable + 0.001 ? .orange : fit.level < 0 ? Theme.nameplateRed : .secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var icon: (name: String, color: Color) {
        guard article.body.contains(where: { !$0.trimmed.isEmpty }) else { return ("minus.circle", .secondary) }
        guard let s = status, !s.pages.isEmpty else { return ("tray.fill", .orange) }
        if s.overset > 0 { return ("arrow.up.right.circle.fill", .orange) }
        return ("checkmark.circle.fill", .green)
    }

    private var detail: String {
        guard article.body.contains(where: { !$0.trimmed.isEmpty }) else { return "No text" }
        guard let s = status, !s.pages.isEmpty else { return String(format: "On hold · about %.1f in² of text", estimate) }
        var where_ = s.pages.count == 1 ? (s.pages[0] == 1 ? "Front page" : "Page \(s.pages[0])")
            : s.pages.map { $0 == 1 ? "Front" : "\($0)" }.joined(separator: " → ")
        if let fit { where_ += String(format: " · %.1f in²", fit.area) }
        if s.overset > 0 { where_ += " · \(s.overset) lines online" }
        return where_
    }
}

/// A story's photos and pull quote as small chips under its row: drag one onto a page to place it (or move it),
/// click one that's placed to find it, right-click for a page.
struct ArtChips: View {
    @Environment(IssueStore.self) private var store
    let article: Article
    let pageCount: Int

    var body: some View {
        let art = store.artPlacements()
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(article.photos.enumerated()), id: \.element.id) { i, p in
                ArtChip(item: .photo(article.id, p.id), image: store.composer.image(p.path), kind: i == 0 ? "lead" : "photo",
                        title: p.caption.trimmed.isEmpty ? (i == 0 ? "Lead photo" : "Photo \(i + 1)") : p.caption.trimmed,
                        placed: art.photos[p.id], pageCount: pageCount)
            }
            if !article.pullQuote.trimmed.isEmpty {
                ArtChip(item: .quote(article.id), image: nil, kind: "quote", title: article.pullQuote.trimmed,
                        placed: art.quotes[article.id], pageCount: pageCount)
            }
        }
        .padding(.bottom, 2)
    }
}

struct ArtChip: View {
    @Environment(IssueStore.self) private var store
    let item: DragItem
    let image: NSImage?
    let kind: String
    let title: String
    let placed: (page: Int, id: Inset.ID)?
    let pageCount: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.rainbow)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.rainbow.opacity(0.12))
                    }
                }
                .frame(width: 46, height: 36)
                .clipShape(shape)
                .overlay(shape.strokeBorder(placed == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(Color.green.opacity(0.7)), lineWidth: placed == nil ? 0.5 : 1.5))
                if placed != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 12))
                        .offset(x: 4, y: -4)
                }
            }
            Text(placed.map { "p. \($0.page + 1)" } ?? kind)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .overlay(RowDragSource(item: item, title: title, image: image) {
            if let placed { store.canvasSelection = .inset(placed.id); store.focusedPage = placed.page }
        })
        .contextMenu {
            Menu(placed == nil ? "Place on Page" : "Move to Page") {
                ForEach(0..<max(1, pageCount), id: \.self) { p in
                    Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.place(item, on: p) }
                }
            }
            if let placed {
                Button("Show on Page") { store.canvasSelection = .inset(placed.id); store.focusedPage = placed.page }
                Button("Remove from Page", role: .destructive) { store.removeInset(placed.id) }
            }
        }
        .help(placed.map { "\(title) · on page \($0.page + 1). Drag to move it." } ?? "\(title) · not on any page. Drag it onto one.")
    }
}

struct ExtraStatusRow: View {
    @Environment(IssueStore.self) private var store
    let extra: Extra
    let pages: [Int]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pages.isEmpty ? "tray.fill" : "checkmark.circle.fill")
                .foregroundStyle(pages.isEmpty ? .orange : .green)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(extra.title.isEmpty ? "Untitled \(extra.kind.rawValue.lowercased())" : extra.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                let g = store.grid
                let w = g.span(extra.columns.clamped(1, g.columns))
                let h = extra.height ?? w / store.composer.aspect(path: extra.path)
                Text((pages.isEmpty ? "Waiting" : "Page " + pages.map(String.init).joined(separator: ", ")) +
                     String(format: " · %@ · %d col · %.1f in²", extra.kind.rawValue, extra.columns, w * h / 5184))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Drawing a page

final class PageNSView: NSView {
    var page: ComposedPage? { didSet { if page !== oldValue { needsDisplay = true } } }
    var guides = false { didSet { if guides != oldValue { needsDisplay = true } } }
    var markers = false { didSet { if markers != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks belong to the SwiftUI layer above

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(HouseStyle.page)                                // draw in page points at any zoom
    }

    override func draw(_ dirtyRect: NSRect) {
        page?.draw(guides: guides, markers: markers)
    }
}

struct PageRenderView: NSViewRepresentable {
    let page: ComposedPage
    var guides = false
    var markers = false

    func makeNSView(context: Context) -> PageNSView {
        let v = PageNSView()
        v.page = page
        v.guides = guides
        v.markers = markers
        return v
    }

    func updateNSView(_ v: PageNSView, context: Context) {
        v.page = page
        v.guides = guides
        v.markers = markers
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
