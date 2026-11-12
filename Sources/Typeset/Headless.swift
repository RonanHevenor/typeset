import AppKit
import SwiftUI

/// A dragging session for the test harness: a pasteboard and a pointer location, nothing more.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    init(pasteboard: NSPasteboard, location: NSPoint) { self.pasteboard = pasteboard; self.location = location }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var draggingFormation: NSDraggingFormation = .default
}

/// `Typeset --render [--issue issue.json] [--out paper.pdf] [--seed N | --as-is] [--fill-header] [--guides] [--json layout.json] [--idml paper.idml [--link-images]]`
/// Lays out an issue without opening a window, using the same generator and composer as the app.
/// `Typeset --make-components [dir]` writes the shipped Header and Folio as component files (Resources/Components).
enum Headless {
    static func run(_ args: [String]) -> Int32 {
        FontLoader.registerBundledFonts()
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if args.contains("--make-components") {
            let dir = URL(fileURLWithPath: value("--make-components").flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "Resources/Components")
            do {
                try BuiltInComponents.write(to: dir)
                print("wrote Header and Folio to \(dir.path); this build's bundle has \(BuiltInComponents.shippedNames.isEmpty ? "neither as a file" : BuiltInComponents.shippedNames.joined(separator: " and ") + " as files")")
                return 0
            }
            catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); return 1 }
        }
        let seed = UInt64(value("--seed") ?? "1") ?? 1
        let out = URL(fileURLWithPath: value("--out") ?? "paper.pdf")
        guard let source = value("--issue").map({ URL(fileURLWithPath: $0) })
                ?? Bundle.main.url(forResource: "seed-issue", withExtension: "json") else {
            FileHandle.standardError.write("no issue: pass --issue <file.json>, or put a seed-issue.json in Resources/Private\n".data(using: .utf8)!)
            return 1
        }
        guard var issue = IssueStore.load(from: source) else {
            FileHandle.standardError.write("can't read \(source.path)\n".data(using: .utf8)!)
            return 1
        }

        let composer = Composer()
        let t0 = Date()
        // --as-is keeps the layout saved in the issue (the paper as edited); otherwise the generator runs with --seed
        if !(args.contains("--as-is") && issue.layout != nil) {
            issue.generateLayout(composer: composer, seed: seed)
        }
        // --fill-header: the Header's teaser frames take stories 3–5 and its image frame the first of their
        // photos, as the generator teased them before phase 4 (what repro/compare.sh checks against)
        if args.contains("--fill-header") {
            let stories = issue.articles.filter { $0.body.contains { !$0.trimmed.isEmpty } }
            issue.fillHeader(with: Array(stories.dropFirst(2).prefix(BuiltInComponents.headerTeaserLinks.count)))
        }
        let t1 = Date()
        let pages = composer.compose(issue)
        let t2 = Date()
        PDFExport.write(pages, to: out, guides: args.contains("--guides"))
        if let json = value("--json"), let data = try? IssueStore.encoder().encode(issue.layout) {
            try? data.write(to: URL(fileURLWithPath: json))
        }

        let byID = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let layout = issue.layout!
        print(String(format: "%d pages · %d columns · %.1f characters per line · generate %.0f ms · compose %.0f ms",
                     pages.count, layout.columns, layout.charsPerLine, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
        for (p, page) in zip(layout.pages, pages) {
            print("page \(page.number)  \(page.section)")
            for b in p.stories {
                let f = b.frame
                let head = byID[b.article]?.plainHeadline.prefix(44) ?? "?"
                print(String(format: "   story  %@  %d col  x %.0f y %.0f w %.0f h %.0f", String(head) as NSString, b.columns, f.x, f.y, f.w, f.h))
            }
            for i in p.insets {
                let f = i.frame
                print(String(format: "   %@  x %.0f y %.0f w %.0f h %.0f", i.kind.rawValue as NSString, f.x, f.y, f.w, f.h))
            }
            for o in page.oversets { print("   OVERSET \(o.lines) lines: \(o.story.prefix(50))") }
            for o in page.online { print("   ONLINE \(o.lines) lines: \(o.story.prefix(50))") }
            for b in page.blanks { print("   \(b.orphan != nil ? "ORPHAN block, story ended on page \(b.orphan!)" : "BLANK \(b.lines) lines"): \(b.story.prefix(50))") }
            for h in page.holes { print(String(format: "   HOLE %.1f in² at x %.0f y %.0f w %.0f h %.0f", h.area, h.rect.minX, h.rect.minY, h.rect.width, h.rect.height)) }
        }
        let fits = composer.fits
        var tight = 0, loose = 0, exact = 0
        for a in issue.articles {
            guard let f = fits[a.id] else { continue }
            if f.overset > 0 || f.level < -0.004 { tight += 1 } else if f.level > 0.004 { loose += 1 } else { exact += 1 }
            print(String(format: "   fit %@: level %+.2f (%+.1f%%) area %.1f in² spare %.1f short %.1f empty lines %d%@", String(a.plainHeadline.prefix(34)) as NSString, f.level, f.percent * 100, f.area, f.spare, f.short, max(0, f.room - f.used),
                         f.places > 0 ? " · local: \(f.places)¶ \(f.localLines >= 0 ? "+" : "")\(f.localLines) lines" as NSString : "" as NSString)
                  + (args.contains("--fit-keys") ? " · fit \(composer.settings[a.id].map { s in "\(Int((s.level * 100).rounded())) " + s.local.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.from)@\(Int(($0.value.level * 100).rounded()))" }.joined(separator: ",") } ?? "-")" : ""))
        }
        print("copyfit: \(tight) tightened, \(loose) loosened, \(exact) at house style")
        print("wrote \(out.path)")
        if let idml = value("--idml") {
            do {
                let linked = args.contains("--link-images")
                let url = try IDMLExport.write(issue, pages: pages, composer: composer, to: URL(fileURLWithPath: idml), embedImages: !linked)
                print("wrote \(url.path)\(linked ? " (+ Links/)" : ", pictures embedded")")
            } catch {
                FileHandle.standardError.write("IDML export failed: \(error)\n".data(using: .utf8)!)
                return 1
            }
        }
        return 0
    }
}

/// `Typeset --snapshot --stage stories|priority|pages [--out shot.png] [--size 1280x860] [--move]`
/// Renders the window's content offscreen to a PNG, for checking the screens without showing a window.
/// Set GALLEY_DATA_DIR so the run uses its own copy of the issue.
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard ProcessInfo.processInfo.environment["GALLEY_DATA_DIR"] != nil else {
            FileHandle.standardError.write("set GALLEY_DATA_DIR to a scratch folder\n".data(using: .utf8)!)
            return 1
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        FontLoader.registerBundledFonts()

        let store = IssueStore(backgroundFits: args.contains("--background-fits"))
        let stage = Stage(rawValue: value("--stage") ?? "stories") ?? .stories
        if stage == .pages {
            if store.issue.layout == nil || args.contains("--regenerate") { store.generate() }
            store.issue.stage = .pages
        } else {
            store.issue.stage = stage
        }
        if let z = value("--zoom").flatMap(Double.init) { store.zoom = CGFloat(z) }
        if args.contains("--guides") { store.showGuides = true }
        if args.contains("--select"), let first = store.issue.layout?.pages.dropFirst().first(where: { !$0.insets.isEmpty })?.insets.first {
            store.selectedInset = first.id
        }
        if let page = value("--page").flatMap(Int.init) { store.focusedPage = page - 1 }
        // simulate the drags the canvas makes: nudge the selected picture, or carry it to another page
        if let id = store.selectedInset, let layout = store.issue.layout,
           let from = layout.pages.firstIndex(where: { $0.insets.contains { $0.id == id } }),
           let inset = layout.pages[from].insets.first(where: { $0.id == id }) {
            if let dy = value("--nudge").flatMap(Double.init) {
                store.setInsetFrame(id, page: from, frame: store.snap(inset.frame.rect.offsetBy(dx: CGFloat(value("--nudge-x").flatMap(Double.init) ?? 0), dy: CGFloat(dy))))
            }
            if let to = value("--carry-to").flatMap(Int.init) {
                store.moveInset(id, from: from, to: to - 1, frame: store.onPage(inset.frame.rect))
                store.selectedInset = id
            }
        }

        if let n = value("--shuffle").flatMap(Int.init) { store.shufflePage(n - 1); store.focusedPage = n - 1 }
        if args.contains("--no-inspector") { store.showInspector = false }

        // story-block edits, the way the canvas makes them
        let undo = UndoManager()
        store.undoManager = undo
        if args.contains("--mid-drag") { Composer.pointerDown = { true } }      // the pointer is held down for the snapshot
        if args.contains("--clear-pages") { store.clearPages() }
        if args.contains("--add-page") { store.addPage() }
        if let n = value("--clear-page").flatMap(Int.init) { store.clearPage(n - 1) }
        func pair(_ flag: String) -> (CGFloat, CGFloat)? {
            guard let v = value(flag) else { return nil }
            let p = v.split(separator: ",").compactMap { Double($0) }
            return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
        }
        if let k = value("--select-block").flatMap(Int.init) {
            let page = store.focusedPage ?? 1
            if let b = store.issue.layout?.pages[safe: page]?.readingOrder[safe: k - 1] { store.canvasSelection = .block(b.id) }
        }
        if let (dx, dy) = pair("--move-block"), let id = store.selectedBlock, let (page, b) = store.block(id) {
            store.beginEdit()
            let insets = store.insets(with: b, on: page)
            let (r, guides) = store.snap(b.frame.rect.offsetBy(dx: dx, dy: dy), page: page, excluding: Set([id] + insets.map(\.id)))
            for i in insets { store.setInsetFrame(i.id, page: page, frame: i.frame.rect.offsetBy(dx: r.minX - b.frame.x, dy: r.minY - b.frame.y)) }
            store.setBlockFrame(id, page: page, frame: r)
            store.endEdit("Move Story")
            store.activeGuides = (page, guides)      // left showing, as mid-drag
        }
        // pulling an edge: --from-edge names it (nw n ne e se s sw w), the pair is how far the pointer moved
        let zoneNames: [String: ResizeZone] = ["nw": .nw, "n": .n, "ne": .ne, "e": .e, "se": .se, "s": .s, "sw": .sw, "w": .w]
        let edge = zoneNames[value("--from-edge") ?? "se"] ?? .se
        if let (dx, dy) = pair("--resize-block"), let id = store.selectedBlock, let (page, b) = store.block(id) {
            store.beginEdit()
            var fitHeight: CGFloat?
            if edge.vertical, let a = store.article(b.article) {              // what the canvas shows while an edge is pulled
                let h = store.fitHeights(b, on: page, article: a)
                let f = b.frame.rect
                let bottom = edge.edges.contains(.bottom)
                store.fitBand = (page, bottom ? CGRect(x: f.minX, y: f.minY + h.tight, width: f.width, height: h.loose - h.tight)
                                               : CGRect(x: f.minX, y: f.maxY - h.loose, width: f.width, height: h.loose - h.tight),
                                 bottom ? f.minY + h.house : f.maxY - h.house)
                fitHeight = h.house
            }
            let (snapped, guides) = store.resizedBlock(id, start: b.frame.rect, zone: edge, dx: dx, dy: dy, page: page, fitHeight: fitHeight)
            store.setBlockFrame(id, page: page, frame: snapped)
            // --mid-drag: the pointer is still down; --stuck-drag: the canvas never heard the drag end
            if !args.contains("--mid-drag"), !args.contains("--stuck-drag") { store.endEdit("Resize Story"); store.fitBand = nil }
            store.activeGuides = (page, guides)
        }
        if let k = value("--select-inset").flatMap(Int.init) {
            let page = store.focusedPage ?? 0
            if let i = store.issue.layout?.pages[safe: page]?.insets[safe: k - 1] { store.canvasSelection = .inset(i.id) }
        }
        if let (dx, dy) = pair("--nudge-inset"), let id = store.selectedInset, let layout = store.issue.layout,
           let page = layout.pages.firstIndex(where: { $0.insets.contains { $0.id == id } }),
           let inset = layout.pages[page].insets.first(where: { $0.id == id }) {
            let (r, guides) = store.snap(inset.frame.rect.offsetBy(dx: dx, dy: dy), page: page, excluding: [id], outline: store.outline(of: inset))
            store.edit("Move Photo") { store.setInsetFrame(id, page: page, frame: store.onPage(r)) }
            store.activeGuides = (page, guides)
            print(String(format: "   picture moved by %.0f,%.0f -> x %.0f y %.2f, outline centre %.2f (guides: %@)", dx, dy, r.minX, r.minY, r.minY + store.outline(of: inset) / 2,
                         guides.map { "\($0.axis == .y ? "y" : "x")=\(Int($0.at))" }.joined(separator: " ") as NSString))
        }
        if let (dx, dy) = pair("--resize-inset"), let id = store.selectedInset, let layout = store.issue.layout,
           let page = layout.pages.firstIndex(where: { $0.insets.contains { $0.id == id } }),
           let inset = layout.pages[page].insets.first(where: { $0.id == id }) {
            store.beginEdit()
            let (r, guides) = store.resizedInset(inset, start: inset.frame.rect, zone: edge, dx: dx, dy: dy, free: args.contains("--crop"), page: page)
            store.setInsetFrame(id, page: page, frame: r)
            store.endEdit("Resize Photo")
            store.activeGuides = (page, guides)
        }
        if let (dx, dy) = pair("--carry-block-to"), let id = store.selectedBlock, let (page, b) = store.block(id) {
            // dx: target page number, dy: top y on that page
            store.edit("Move Story") { store.moveBlock(id, from: page, to: Int(dx) - 1, frame: CGRect(x: b.frame.x, y: dy, width: b.frame.w, height: b.frame.h)) }
        }
        if let n = value("--columns").flatMap(Int.init), let id = store.selectedBlock { store.setColumns(n, block: id) }
        if args.contains("--fit-block"), let id = store.selectedBlock { store.fitBlock(id) }
        if args.contains("--fill-block"), let id = store.selectedBlock { store.fillDown(id) }
        if args.contains("--fill-space"), let id = store.selectedBlock { store.fillSpace(id) }
        if args.contains("--remove-block"), let id = store.selectedBlock { store.removeBlock(id) }
        if let k = value("--add-story").flatMap(Int.init), let p = value("--on-page").flatMap(Int.init),
           let a = store.issue.articles[safe: k - 1] {
            store.addBlock(a.id, on: p - 1)
        }
        // a story's own art, placed by hand: --add-photo K [--photo-index N] / --add-quote K, with --on-page P [--place-at x,y]
        if let k = value("--add-photo").flatMap(Int.init), let p = value("--on-page").flatMap(Int.init),
           let a = store.issue.articles[safe: k - 1], let photo = a.photos[safe: (value("--photo-index").flatMap(Int.init) ?? 1) - 1] {
            store.placePhoto(photo.id, of: a.id, on: p - 1, at: pair("--place-at").map { CGPoint(x: $0.0, y: $0.1) })
        }
        if let k = value("--add-quote").flatMap(Int.init), let p = value("--on-page").flatMap(Int.init), let a = store.issue.articles[safe: k - 1] {
            store.placePullQuote(of: a.id, on: p - 1, at: pair("--place-at").map { CGPoint(x: $0.0, y: $0.1) })
        }
        // the drop preview, as if story K were hovering over page P at x,y
        if let k = value("--preview-story").flatMap(Int.init), let p = value("--on-page").flatMap(Int.init), let at = pair("--place-at"),
           let a = store.issue.articles[safe: k - 1] {
            store.inspectorDrag = .story(a.id)
            store.dropTarget = p - 1
            store.dropPreview = store.frame(for: .story(a.id), on: p - 1, at: CGPoint(x: at.0, y: at.1))
            store.focusedPage = p - 1
        }
        // an AppKit drag session, faked: story K dragged over page P and let go at x,y
        if let k = value("--drop-story").flatMap(Int.init), let p = value("--on-page").flatMap(Int.init), let at = pair("--place-at"),
           let a = store.issue.articles[safe: k - 1] {
            let target = PageDropView(frame: NSRect(x: 0, y: 0, width: HouseStyle.page.width * store.zoom, height: HouseStyle.page.height * store.zoom))
            target.store = store; target.index = p - 1
            let pb = NSPasteboard(name: NSPasteboard.Name("galley-test-drag"))
            pb.clearContents()
            let item = NSPasteboardItem(); item.setString(DragItem.story(a.id).string, forType: .string)
            pb.writeObjects([item])
            // window coordinates run upward; the drop view is flipped and converts them
            let info = FakeDraggingInfo(pasteboard: pb, location: NSPoint(x: at.0 * store.zoom, y: (HouseStyle.page.height - at.1) * store.zoom))
            DragSession.active = true
            let hit = target.hitTest(NSPoint(x: 10, y: 10)) === target
            DragSession.active = false
            let idle = target.hitTest(NSPoint(x: 10, y: 10)) == nil
            print("   drop target hit while dragging: \(hit); passes clicks through when idle: \(idle)")
            let op = target.draggingEntered(info)
            print("   draggingEntered -> \(op == .copy ? "copy" : "none"); preview \(store.dropPreview.map { String(format: "x %.0f y %.0f w %.0f h %.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none") target page \(store.dropTarget.map { $0 + 1 } ?? 0)")
            let done = target.performDragOperation(info)
            print("   performDragOperation -> \(done); read back: \(DragItem.read(pb).map(\.string) ?? "nothing")")
        }
        if let out = value("--drag-image") {
            let photo = store.issue.articles.flatMap(\.photos).first.flatMap { store.composer.image($0.path) }
            let img = RowDragView.dragImage(title: "Rensselaer gets clobbered by the Pioneers, again and again", image: photo)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("   drag image \(Int(img.size.width))x\(Int(img.size.height)) -> \(out)")
            }
        }
        // drag the selected block's bottom edge through a range of heights and see how the fit comes out at each:
        // how wide the window is where the story sets comfortably, and whether house style is reachable
        if args.contains("--scan-fit"), let id = store.selectedBlock, let (page, b) = store.block(id), let a = store.article(b.article) {
            let h = store.fitHeights(b, on: page, article: a)
            print(String(format: "   %@: fits at house style %.0f pt · comfortable band %.0f … %.0f pt (%.0f%% of the block)",
                         String(a.plainHeadline.prefix(30)) as NSString, h.house, h.tight, h.loose, (h.loose - h.tight) / h.house * 100))
            var inBand = 0, total = 0, over = 0
            var line = "   "
            let step: CGFloat = 10
            var height = (h.house * 0.75 / step).rounded() * step
            while height <= h.house * 1.3 {
                store.edit("Scan") { store.setBlockFrame(id, page: page, frame: CGRect(x: b.frame.x, y: b.frame.y, width: b.frame.w, height: height)) }
                let f = store.fits[a.id]
                let level = f?.level ?? 0, overset = f?.overset ?? 0
                total += 1
                if overset > 0 { over += 1 } else if abs(level) <= Fit.comfortable + 0.001 { inBand += 1 }
                line += String(format: "%.0f:%@%+.2f ", height, overset > 0 ? "!" : "", level)
                height += step
            }
            print(line)
            print("   \(inBand) of \(total) heights set comfortably, \(over) overset; the rest set hard")
            store.edit("Scan") { store.setBlockFrame(id, page: page, frame: b.frame.rect) }
        }
        // how long each pointer move costs while a block edge is dragged, and the release after
        if args.contains("--profile-drag"), let id = store.selectedBlock, let (page, b) = store.block(id) {
            func render() {           // what one screen update asks the store for
                _ = store.composedPages; _ = store.fits; _ = store.storyStatus(); _ = store.composedPages; _ = store.fits
                _ = store.composedPages; _ = store.fits; _ = store.composedPages
            }
            render()
            var times: [Double] = []
            store.beginEdit()
            Composer.pointerDown = { true }                                  // the pointer is down for the whole drag
            var r = b.frame.rect
            for _ in 0..<20 {
                r.size.height -= 2
                let t0 = Date()
                store.setBlockFrame(id, page: page, frame: r)
                render()
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            Composer.pointerDown = { false }
            let t1 = Date()
            store.endEdit("Resize Story")
            render()
            let release = Date().timeIntervalSince(t1) * 1000
            let t2 = Date()
            render()
            let idle = Date().timeIntervalSince(t2) * 1000
            print(String(format: "   drag step: avg %.1f ms, max %.1f ms over %d steps · release %.1f ms · idle render %.2f ms",
                         times.reduce(0, +) / Double(times.count), times.max() ?? 0, times.count, release, idle))
            Composer.profile = false
        }
        // --profile-edit: the two heavy drags, step by step, with where the time goes. On the focused page: the
        // first block's bottom edge pulled up and back down, then the first photo dragged down through the text.
        if args.contains("--profile-edit"), let pi = store.focusedPage, let pl = store.issue.layout?.pages[safe: pi] {
            let background = store.composer.worker != nil
            func render() {           // what one screen update asks the store for
                _ = store.displayPages; _ = store.fits; _ = store.storyStatus(); _ = store.displayPages; _ = store.fits
                _ = store.displayPages; _ = store.fits; _ = store.displayPages
            }
            /// With background fits: how long until every page shows its exact fits.
            func settle() -> Double {
                let t0 = Date()
                while store.displayPages.contains(where: \.provisional), Date().timeIntervalSince(t0) < 10 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                }
                return Date().timeIntervalSince(t0) * 1000
            }
            if background { print(String(format: "   first paper with background fits: shown at once, settled in %.0f ms", settle())) }
            func report(_ name: String, _ steps: [(ms: Double, s: Composer.Stats)], release: Double) {
                let ms = steps.map(\.ms).sorted()
                let tot = steps.reduce(Composer.Stats()) { a, b in
                    var t = a; t.measures += b.s.measures; t.measureMs += b.s.measureMs; t.fits += b.s.fits; t.fitMs += b.s.fitMs
                    t.pages += b.s.pages; t.pageMs += b.s.pageMs; t.composeMs += b.s.composeMs; return t }
                let n = Double(steps.count)
                print(String(format: "   %@: step median %.1f ms, 90th %.1f, max %.1f over %d steps · release %.1f ms", name as NSString,
                             ms[ms.count / 2], ms[Int(Double(ms.count) * 0.9)], ms.last!, steps.count, release))
                print(String(format: "      per step: %.1f story fits (%.1f ms), %.1f measures (%.1f ms), %.1f pages set (%.1f ms), compose total %.1f ms, other %.1f ms",
                             Double(tot.fits) / n, tot.fitMs / n, Double(tot.measures) / n, tot.measureMs / n, Double(tot.pages) / n, tot.pageMs / n,
                             tot.composeMs / n, (steps.map(\.ms).reduce(0, +) - tot.composeMs) / n))
            }
            render()
            Composer.pointerDown = { true }
            if let b = pl.readingOrder.first, let a = store.article(b.article) {
                store.canvasSelection = .block(b.id)
                var steps: [(Double, Composer.Stats)] = []
                store.beginEdit()
                let h = store.fitHeights(b, on: pi, article: a)
                for k in 0..<30 {
                    let dy = CGFloat(k < 15 ? -3 * (k + 1) : -3 * (30 - k))
                    Composer.stats = .init()
                    let t0 = Date()
                    let (r, _) = store.resizedBlock(b.id, start: b.frame.rect, zone: .s, dx: 0, dy: dy, page: pi, fitHeight: h.house)
                    store.setBlockFrame(b.id, page: pi, frame: r)
                    render()
                    steps.append((Date().timeIntervalSince(t0) * 1000, Composer.stats))
                }
                Composer.pointerDown = { false }
                let t1 = Date(); store.endEdit("Resize Story"); render()
                report("block bottom edge", steps, release: Date().timeIntervalSince(t1) * 1000)
                if background { print(String(format: "      exact fits on screen %.0f ms after letting go", settle())) }
                Composer.pointerDown = { true }
            }
            if let inset = (store.issue.layout?.pages[pi].insets ?? []).first(where: { $0.kind == .photo }) {
                store.canvasSelection = .inset(inset.id)
                var steps: [(Double, Composer.Stats)] = []
                store.beginEdit()
                for k in 1...30 {
                    Composer.stats = .init()
                    let t0 = Date()
                    let (r, _) = store.snap(inset.frame.rect.offsetBy(dx: CGFloat(k) * -4, dy: CGFloat(k) * 12), page: pi, excluding: [inset.id], outline: store.outline(of: inset))
                    store.setInsetFrame(inset.id, page: pi, frame: store.onPage(r))
                    render()
                    steps.append((Date().timeIntervalSince(t0) * 1000, Composer.stats))
                }
                Composer.pointerDown = { false }
                let t1 = Date(); store.endEdit("Move Photo"); render()
                report("photo through text", steps, release: Date().timeIntervalSince(t1) * 1000)
                if background { print(String(format: "      exact fits on screen %.0f ms after letting go", settle())) }
            }
            Composer.pointerDown = { NSEvent.pressedMouseButtons & 1 != 0 }
        }
        // what the page view would make of the pointer at x,y (page points) on the focused page
        for probe in args.indices.filter({ args[$0] == "--probe" }).compactMap({ args.indices.contains($0 + 1) ? args[$0 + 1] : nil }) {
            let v = probe.split(separator: ",").compactMap { Double($0) }
            guard v.count == 2 else { continue }
            let pt = CGPoint(x: v[0], y: v[1]), page = store.focusedPage ?? 0
            let zone = store.zone(at: pt, on: page)
            print("   pointer at \(Int(pt.x)),\(Int(pt.y)): \(zone.map { "resize \($0)" } ?? (store.itemUnder(pt, on: page) ? "move (open hand)" : "nothing (arrow)"))")
        }
        // where a photo under the lead headline starts making it wrap, in points below the headline's descenders
        if args.contains("--headline-probe"), let pl = store.issue.layout?.pages[safe: store.focusedPage ?? 0], let b = pl.readingOrder.first,
           let a = store.article(b.article), let inset = pl.insets.first(where: { $0.kind == .photo && $0.article == b.article }) {
            let f = b.frame.rect
            let font = Composer.headline(a.plainHeadline, size: b.headlineSize).attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            print(String(format: "   headline %.0f pt: ascender %.1f descender %.1f line gap %.1f line box %.1f", b.headlineSize, font.ascender, font.descender, font.leading, NSLayoutManager().defaultLineHeight(for: font)))
            let g0 = store.composer.blockGeometry(a, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: [], bylineColumns: b.bylineColumns, draw: true)
            // the first line's real descender line, from the layout: its fragment, the baseline inside it, the descent below
            let lm = g0.headline!.manager
            let fragment = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let baseline = f.minY + fragment.minY + lm.location(forGlyphAt: 0).y
            let descenders = baseline - font.descender
            print(String(format: "   first line: fragment %.1f tall, baseline %.1f below the block top, descenders %.1f below, body starts %.1f below", fragment.height, baseline - f.minY, descenders - f.minY, g0.bodyTop - f.minY))
            var first: Int?
            for dy in stride(from: -16, through: 24, by: 2) {
                var r = inset.frame.rect; r.origin.y = descenders + CGFloat(dy)
                guard let full = store.composer.geometry(Inset(kind: .photo, article: a.id, photo: inset.photo, frame: Box(r)), a)?.full else { continue }
                let g = store.composer.blockGeometry(a, frame: f, columns: b.columns, headlineSize: b.headlineSize, avoid: [Composer.wrap(full)], bylineColumns: b.bylineColumns, draw: true)
                if g.bodyTop <= g0.bodyTop + 1, first == nil { first = dy }
            }
            print("   the headline stays whole once the photo's top is \(first.map { "\($0) pt" } ?? "never") below its descenders")
        }
        if args.contains("--park"), let id = store.selectedBlock, let (_, b) = store.block(id) { store.parkStory(b.article) }
        if let path = value("--add-extra") {
            let kind = Extra.Kind(rawValue: value("--extra-kind") ?? "Ad") ?? .ad
            if let id = store.addExtra(kind, file: URL(fileURLWithPath: path)) {
                if let k = store.issue.extras.firstIndex(where: { $0.id == id }) {
                    if let n = value("--extra-columns").flatMap(Int.init) { store.issue.extras[k].columns = n }
                    if let h = value("--extra-height").flatMap(Double.init) { store.issue.extras[k].height = CGFloat(h) }
                }
                if let p = value("--place-on").flatMap(Int.init) {
                    let at = pair("--place-at").map { CGPoint(x: $0.0, y: $0.1) }
                    store.placeExtra(id, on: p - 1, at: at)
                }
            }
        }
        if let n = value("--fill-holes").flatMap(Int.init) { store.fillHoles(on: n - 1) }
        if args.contains("--drop-outside"), let sel = store.canvasSelection { store.dropOutside(sel) }
        if let n = value("--undo").flatMap(Int.init) { for _ in 0..<n { undo.undo() } }
        if args.contains("--report") {
            let fits = store.fits
            for (id, st) in store.storyStatus().sorted(by: { ($0.value.pages.first ?? 99) < ($1.value.pages.first ?? 99) }) {
                let name = store.article(id)?.plainHeadline.prefix(36) ?? "?"
                var line = "   \(name): pages \(st.pages) overset \(st.overset) empty \(st.empty)"
                if let f = fits[id] {
                    line += String(format: "  fit %+.2f (%+.1f%%) area %.1f spare %.1f short %.1f blank %d orphans %d", f.level, f.percent * 100, f.area, f.spare, f.short, f.blank, f.orphans)
                    if f.places > 0 { line += " local \(f.places)¶ \(f.localLines >= 0 ? "+" : "")\(f.localLines)" }
                }
                print(line)
            }
            for (i, pg) in (store.issue.layout?.pages ?? []).enumerated() {
                for b in pg.readingOrder {
                    guard let r = store.composedPages[safe: i]?.blockResults[b.id] else { continue }
                    let (text, warn) = blockStatus(r, article: store.article(b.article), store: store)
                    print("   page \(i + 1) block \(store.article(b.article)?.plainHeadline.prefix(24) ?? "?") [\(b.columns) col, head \(Int(b.headlineSize)) pt, h \(Int(b.frame.h))]: \(text)\(warn ? " !" : "")")
                }
            }
            for (e, p) in store.extraPages() { print("   extra \(store.extra(e)?.title ?? "?"): pages \(p)") }
            for (i, pg) in (store.issue.layout?.pages ?? []).enumerated() {
                for inset in pg.insets {
                    let f = inset.frame
                    let who = inset.kind == .extra ? (store.extra(inset.extra)?.title ?? "?") : (store.article(inset.article)?.plainHeadline.prefix(30)).map(String.init) ?? "?"
                    print(String(format: "   page %d %@ (%@): x %.0f y %.0f w %.0f h %.0f", i + 1, inset.kind.rawValue as NSString, who as NSString, f.x, f.y, f.w, f.h))
                }
            }
            if let sel = store.selectedBlock, let (p, b) = store.block(sel) {
                print(String(format: "   selected block on page %d: x %.0f y %.0f w %.0f h %.0f", p + 1, b.frame.x, b.frame.y, b.frame.w, b.frame.h))
            }
            if let p = store.dropPreview { print(String(format: "   drop preview: x %.0f y %.0f w %.0f h %.0f", p.minX, p.minY, p.width, p.height)) }
            for (i, cp) in store.composedPages.enumerated() where cp.hasProblems {
                print("   page \(i + 1): overset \(cp.oversets.map(\.lines)) blank \(cp.blanks.map(\.lines)) holes " + cp.holes.map { String(format: "%.1f", $0.area) }.joined(separator: ","))
            }
        }

        let dims = (value("--size") ?? (stage == .pages ? "1500x900" : "1280x860")).split(separator: "x").compactMap { Double($0) }
        let size = CGSize(width: dims.first ?? 1280, height: dims.last ?? 860)
        let root = ContentView().environment(store).tint(Theme.brandSolid)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        if let dark = value("--appearance"), dark == "dark" { window.appearance = NSAppearance(named: .darkAqua) }
        else { window.appearance = NSAppearance(named: .aqua) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        // the canvas scrolls to the focused page when it changes; re-announce it now that the views exist
        let focus = store.focusedPage
        store.focusedPage = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        store.focusedPage = focus
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let view: NSView = window.contentView?.superview ?? host
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = URL(fileURLWithPath: value("--out") ?? "shot.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("wrote \(out.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        store.saveNow()
        return 0
    }
}
