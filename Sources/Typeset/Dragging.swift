import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

let dragLog = Logger(subsystem: "edu.rpi.poly.galley", category: "drag")

// MARK: - Dragging from the inspector

/// Something dragged from the inspector onto a page. It rides the pasteboard as plain text, so it travels through
/// AppKit's drag session like anything else and lands wherever the pointer lets go.
enum DragItem: Hashable {
    case story(Article.ID)
    case photo(Article.ID, Photo.ID)
    case quote(Article.ID)
    case extra(Extra.ID)
    /// A component from the sidebar, at the version picked there.
    case component(Component.ID, Int)

    var string: String {
        switch self {
        case .story(let a): "story:\(a.uuidString)"
        case .photo(let a, let p): "photo:\(a.uuidString)/\(p.uuidString)"
        case .quote(let a): "quote:\(a.uuidString)"
        case .extra(let e): "extra:\(e.uuidString)"
        case .component(let c, let v): "component:\(c.uuidString)/\(v)"
        }
    }

    init?(_ s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "story": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .story(id)
        case "quote": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .quote(id)
        case "extra": guard let id = UUID(uuidString: parts[1]) else { return nil }; self = .extra(id)
        case "photo":
            let ids = parts[1].split(separator: "/").map(String.init)
            guard ids.count == 2, let a = UUID(uuidString: ids[0]), let p = UUID(uuidString: ids[1]) else { return nil }
            self = .photo(a, p)
        case "component":
            let ids = parts[1].split(separator: "/").map(String.init)
            guard ids.count == 2, let c = UUID(uuidString: ids[0]), let v = Int(ids[1]) else { return nil }
            self = .component(c, v)
        default: return nil
        }
    }

    var provider: NSItemProvider { NSItemProvider(object: string as NSString) }

    /// The pasteboard types a dragged item shows up as.
    static let types: [UTType] = [.utf8PlainText, .plainText, .text]

    /// The item on a drag pasteboard, if it carries one.
    static func read(_ pb: NSPasteboard) -> DragItem? {
        pb.string(forType: .string).flatMap(DragItem.init)
    }
}

/// Whether one of our own drags is in flight. The page drop targets only take hits while it is, so clicks on the
/// canvas keep going to the handles.
enum DragSession {
    static var active = false
}

// MARK: AppKit drag source

/// A transparent AppKit view over an inspector row that starts a real drag session when the pointer is pulled
/// across it. A plain click goes to `onTap`; right-clicks fall through to the row's context menu underneath.
struct RowDragSource: NSViewRepresentable {
    @Environment(IssueStore.self) private var store
    let item: DragItem
    let title: String
    var image: NSImage? = nil
    var onTap: () -> Void = {}

    func makeNSView(context: Context) -> RowDragView { RowDragView() }

    func updateNSView(_ v: RowDragView, context: Context) {
        v.item = item; v.title = title; v.image = image; v.onTap = onTap; v.store = store
    }
}

final class RowDragView: NSView, NSDraggingSource {
    var item: DragItem?
    var title = ""
    var image: NSImage?
    var onTap: (() -> Void)?
    weak var store: IssueStore?
    private var downAt: NSPoint?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // left-button events are ours; everything else (hover, right-click for the menu) belongs to the row below
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil { downAt = nil; onTap?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, let item else { return }
        let p = event.locationInWindow
        guard hypot(p.x - d.x, p.y - d.y) > 4 else { return }
        downAt = nil
        store?.inspectorDrag = item
        DragSession.active = true
        dragLog.info("drag begins: \(item.string, privacy: .public)")
        let pb = NSPasteboardItem()
        pb.setString(item.string, forType: .string)
        let di = NSDraggingItem(pasteboardWriter: pb)
        let img = Self.dragImage(title: title, image: image)
        let at = convert(event.locationInWindow, from: nil)
        di.setDraggingFrame(NSRect(x: at.x - 12, y: at.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLog.info("drag ends: \(operation.rawValue)")
        DragSession.active = false
        store?.inspectorDrag = nil
        store?.dropTarget = nil
        store?.dropPreview = nil
        store?.activeGuides = nil
    }

    /// What follows the pointer: a small card with the thumbnail and the name.
    static func dragImage(title: String, image: NSImage?) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = NSAttributedString(string: title.isEmpty ? "Untitled" : title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let textW = min(220, ceil(text.size().width))
        let thumbW: CGFloat = image == nil ? 0 : 40
        let size = NSSize(width: 16 + thumbW + (image == nil ? 0 : 8) + textW, height: 36)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
            var x: CGFloat = 8
            if let image {
                let r = NSRect(x: x, y: 3, width: thumbW, height: 30)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
                // fill the thumbnail the way the chip does: scale to cover, centred
                let a = image.size.width / max(1, image.size.height)
                let fit = a > r.width / r.height ? NSRect(x: r.midX - r.height * a / 2, y: r.minY, width: r.height * a, height: r.height)
                                                 : NSRect(x: r.minX, y: r.midY - r.width / a / 2, width: r.width, height: r.width / a)
                image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                x += thumbW + 8
            }
            text.draw(with: NSRect(x: x, y: (size.height - ceil(text.size().height)) / 2, width: textW, height: ceil(text.size().height)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}

// MARK: AppKit page view: the pointer and drops

/// The one AppKit view over a page. It takes every left-button press, drag and release over the page (and over
/// the selected item's edge band just past the page's edge), and every pointer move, and feeds them to the
/// store's pointer state machine in page points. Right-clicks, scrolls and pinches pass through. While one of our
/// inspector drags is in flight it is also the page's drop target.
struct PageDropTarget: NSViewRepresentable {
    @Environment(IssueStore.self) private var store
    @Environment(CanvasPointerUI.self) private var ui
    let index: Int
    /// How far the view reaches past the page on every side, in screen points.
    var pad: CGFloat = 0

    func makeNSView(context: Context) -> PageDropView { PageDropView() }

    func updateNSView(_ v: PageDropView, context: Context) {
        v.store = store; v.index = index; v.pad = pad; v.ui = ui
        ui.views[index] = .init(view: v)
    }
}

final class PageDropView: NSView {
    weak var store: IssueStore?
    weak var ui: CanvasPointerUI?
    var index = 0
    /// The band around the page the view covers, in screen points: the selected item's edge reaches past the
    /// page's edge (IB-10).
    var pad: CGFloat = 0
    private var resignObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = resignObserver { NotificationCenter.default.removeObserver(o) } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The page's rect in this view.
    var pageRect: CGRect {
        let z = store?.zoom ?? 1
        return CGRect(x: pad, y: pad, width: HouseStyle.page.width * z, height: HouseStyle.page.height * z)
    }

    /// A point in this view, in page points.
    func pagePoint(_ local: CGPoint) -> CGPoint {
        let z = store?.zoom ?? 1
        return CGPoint(x: (local.x - pad) / z, y: (local.y - pad) / z)
    }

    /// Whether a left press at `local` is this page's: anywhere on the page, and in the band past its edge only
    /// where the selected item's edge is.
    func takesPress(at local: CGPoint) -> Bool {
        guard let store, bounds.contains(local), store.inPlace == nil else { return false }
        if pageRect.contains(local) { return true }
        return store.hit(at: pagePoint(local), on: index).edge != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if DragSession.active { return super.hitTest(point) }
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return takesPress(at: local) ? self : nil
        case .rightMouseDown, .otherMouseDown:
            // the menu underneath asks the hit test what's here: make sure it's asking about this point
            if bounds.contains(local) { hover(at: local) }
            return nil
        case .scrollWheel, .magnify:
            // the canvas moves under a still pointer: work out what's under it once it has
            if bounds.contains(local) { DispatchQueue.main.async { [weak self] in self?.ui?.rehoverAtMouse() } }
            return nil
        default:
            return nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let window else { return }
        // the app or window lost the mouse mid-gesture: the mouse-up won't come (rule 6)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostMouse() }
        }
    }

    /// Close a gesture whose mouse-up will never arrive.
    func lostMouse() {
        guard let store, store.lostMouse() else { return }
        NSCursor.arrow.set()
    }

    // MARK: hover

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        // a plain move with a gesture still open: its mouse-up was lost while the window stayed key (rule 6)
        if let store, store.pointer.isActive, !DragSession.active, NSEvent.pressedMouseButtons & 1 == 0 {
            store.pointerHoverButtonUp(at: nil, on: index)
            ui?.setHovered(nil)
        }
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard let store, !store.pointer.isActive, !DragSession.active else { return }
        leave()
    }

    private func leave() {
        guard let store, store.hover?.page == index else { return }
        store.pointerHover(at: nil, on: index)
        if ui?.hovered?.page == index { ui?.setHovered(nil) }
        toolTip = nil
        NSCursor.arrow.set()
    }

    /// The pointer over this view with no button down: what's under it, from the hit test, sets the hover, the
    /// edge, the cursor and the help text. Returns the hit.
    @discardableResult
    func hover(at local: CGPoint) -> CanvasHit? {
        guard let store, !DragSession.active, bounds.contains(local) else { return nil }
        guard let h = store.pointerHover(at: pagePoint(local), on: index) else { return nil }
        let item = h.selection.map { CanvasPointerUI.Hovered(page: index, item: $0) }
        if item != ui?.hovered { ui?.setHovered(item); toolTip = store.helpText(for: h.selection, on: index) }
        if window != nil { h.cursor.set() }
        return h
    }

    /// Where the mouse is now, in this view's coordinates; a self-test swaps it for a fixed window point.
    static var mouseNow: (PageDropView) -> CGPoint? = { v in
        v.window.map { v.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    func rehoverAtMouse() {
        guard let store, !store.pointer.isActive, let local = Self.mouseNow(self) else { return }
        if bounds.contains(local) { hover(at: local) } else if store.hover?.page == index { leave() }
    }

    // MARK: the press

    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        ui?.fromPointer(store) {
            store.pointerDown(at: p, on: index, modifiers: .init(event.modifierFlags), clickCount: event.clickCount)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let store, store.pointer.isActive else { return }
        let loc = location(event)
        ui?.fromPointer(store) { store.pointerMoved(to: loc, modifiers: .init(event.modifierFlags)) }
        setGestureCursor()
    }

    override func mouseUp(with event: NSEvent) {
        guard let store, store.pointer.isActive else { return }
        if store.pointer.phase == .pressed {
            // no drag event came between the press and this release: let the move start first, so a jump onto
            // another page or the inspector is routed there like any drag
            let first = location(event)
            ui?.fromPointer(store) { store.pointerMoved(to: first, modifiers: .init(event.modifierFlags)) }
        }
        let loc = location(event)
        ui?.fromPointer(store) { store.pointerUp(at: loc, modifiers: .init(event.modifierFlags)) }
        // what's under the pointer now, with the new selection and geometry
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) { hover(at: local) } else { ui?.rehoverAtMouse() }
    }

    /// Where the pointer is for the gesture under way. Only a move looks for the page under the pointer (or the
    /// inspector); a press, resize, crop or byline pull stays on the page it started on, even past its edge.
    func location(_ event: NSEvent) -> IssueStore.PointerLocation {
        guard let store else { return .page(index, .zero) }
        let start = store.pointer.page
        let w = event.locationInWindow
        guard store.pointer.phase == .dragging else {
            let home = ui?.views[start]?.view ?? self
            return .page(start, home.pagePoint(home.convert(w, from: nil)))
        }
        let areas = ui?.pageAreas(in: window) ?? [area()]
        return PointerRouting.location(w, pages: areas, canvasMaxX: canvasMaxX(), inspector: store.showInspector, start: start, zoom: store.zoom)
    }

    /// This page in window coordinates: its whole frame, and the part the canvas shows.
    func area() -> PointerRouting.PageArea {
        let frame = convert(pageRect, to: nil)
        var visible = convert(visibleRect.intersection(pageRect), to: nil)
        if let sv = enclosingScrollView { visible = visible.intersection(sv.convert(sv.bounds, to: nil)) }
        return .init(index: index, frame: frame, visible: visible.isNull ? .zero : visible)
    }

    private func canvasMaxX() -> CGFloat? {
        if let sv = enclosingScrollView { return sv.convert(sv.bounds, to: nil).maxX }
        return ui?.canvasMaxX
    }

    private func setGestureCursor() {
        guard let store else { return }
        switch store.pointer.phase {
        case .dragging: (store.dragOutside ? NSCursor.dragCopy : NSCursor.closedHand).set()
        case .cropping: NSCursor.closedHand.set()
        case .pullingFill: (store.dropPreview != nil ? NSCursor.closedHand : NSCursor.disappearingItem).set()
        case .resizing: store.pointer.zone?.cursor.set()
        case .bylineWidth: NSCursor.resizeLeftRight.set()
        case .marquee: NSCursor.crosshair.set()
        case .idle, .pressed: break
        }
    }

    // MARK: dropping from the inspector

    /// Where the pointer is, in page points.
    private func pagePoint(_ info: NSDraggingInfo) -> CGPoint {
        pagePoint(convert(info.draggingLocation, from: nil))
    }

    /// The dashed preview for an item dragged in from the inspector, with the same snapping and guides as a drag
    /// on the page: ⌘ turns snapping off (IB-14).
    func preview(_ item: DragItem, at p: CGPoint, modifiers: IssueStore.PointerModifiers) {
        guard let store else { return }
        store.dropTarget = index
        store.snapOff = modifiers.contains(.command)
        defer { store.snapOff = false }
        let r = store.frame(for: item, on: index, at: p)
        store.dropPreview = r
        if let r, !modifiers.contains(.command) {
            store.activeGuides = (index, store.snap(r, page: index, move: false).guides)
        } else {
            store.activeGuides = nil
        }
    }

    private func update(_ info: NSDraggingInfo) {
        guard let store else { return }
        if let item = DragItem.read(info.draggingPasteboard) {
            preview(item, at: pagePoint(info), modifiers: .init(NSEvent.modifierFlags))
        } else {
            store.dropTarget = index
            store.dropPreview = nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if store?.inPlace != nil { return [] }                      // the paper takes nothing while a component is edited in place
        dragLog.info("page \(self.index + 1) drag entered, types \(sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-", privacy: .public)")
        update(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if store?.inPlace != nil { return [] }
        update(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let store, store.dropTarget == index else { return }
        store.dropTarget = nil
        store.dropPreview = nil
        store.activeGuides = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { store?.inPlace == nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let store else { return false }
        store.dropTarget = nil
        store.dropPreview = nil
        store.activeGuides = nil
        let point = pagePoint(sender)
        let pb = sender.draggingPasteboard
        if let item = DragItem.read(pb) {
            store.snapOff = NSEvent.modifierFlags.contains(.command)
            defer { store.snapOff = false }
            let ok = store.place(item, on: index, at: point)
            dragLog.info("page \(self.index + 1) drop \(item.string, privacy: .public) at \(Int(point.x)),\(Int(point.y)): \(ok)")
            return ok
        }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var at = point
        for u in urls { store.dropFile(u, on: index, at: at); at.y += 24 }
        dragLog.info("page \(self.index + 1) drop \(urls.count) files")
        return !urls.isEmpty
    }
}

/// Drops onto a page: stories, photos, pull quotes and ads from the inspector, previewed where they'll land as the
/// pointer moves; and image or PDF files from the Finder, which come in as pictures and land where they're dropped.
struct PageDropDelegate: DropDelegate {
    let store: IssueStore
    let index: Int

    func validateDrop(info: DropInfo) -> Bool {
        let ok = store.inPlace == nil && info.hasItemsConforming(to: DragItem.types + [.fileURL])
        dragLog.info("swiftui validateDrop page \(index + 1): \(ok)")
        return ok
    }

    func dropEntered(info: DropInfo) { dragLog.info("swiftui dropEntered page \(index + 1)"); update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if store.dropTarget == index { store.dropTarget = nil; store.dropPreview = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        store.dropTarget = nil
        store.dropPreview = nil
        store.activeGuides = nil
        store.inspectorDrag = nil
        let point = pagePoint(info)
        let snapOff = NSEvent.modifierFlags.contains(.command)
        dragLog.info("swiftui performDrop page \(index + 1) at \(Int(point.x)),\(Int(point.y))")
        let files = info.itemProviders(for: [.fileURL])
        if !files.isEmpty {
            var at = point
            for p in files {
                let here = at
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { store.dropFile(url, on: index, at: here) }
                }
                at.y += 24      // several files fan down the page rather than piling up
            }
            return true
        }
        // what the pasteboard says it is, not what we think is being dragged
        let texts = info.itemProviders(for: DragItem.types)
        for p in texts {
            let type = p.registeredTypeIdentifiers.first { id in DragItem.types.contains { $0.identifier == id } } ?? UTType.utf8PlainText.identifier
            p.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                guard let data, let s = String(data: data, encoding: .utf8), let item = DragItem(s) else {
                    dragLog.error("swiftui drop payload unreadable: \(error?.localizedDescription ?? "-", privacy: .public)")
                    return
                }
                DispatchQueue.main.async { store.snapOff = snapOff; _ = store.place(item, on: index, at: point); store.snapOff = false }
            }
        }
        return !texts.isEmpty
    }

    private func pagePoint(_ info: DropInfo) -> CGPoint {
        CGPoint(x: info.location.x / store.zoom, y: info.location.y / store.zoom)
    }

    private func update(_ info: DropInfo) {
        store.dropTarget = index
        guard let item = store.inspectorDrag, !info.hasItemsConforming(to: [.fileURL]) else { store.dropPreview = nil; return }
        store.snapOff = NSEvent.modifierFlags.contains(.command)
        store.dropPreview = store.frame(for: item, on: index, at: pagePoint(info))
        store.snapOff = false
    }
}

/// The dashed outline of where a dragged item will land, drawn over the page while it hovers.
struct DropPreview: View {
    let rect: CGRect
    let zoom: CGFloat
    let label: String

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(accent.opacity(0.1))
            Rectangle().strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(accent, in: Capsule())
                .fixedSize()
                .offset(x: 4, y: -22)
        }
        .frame(width: rect.width * zoom, height: rect.height * zoom, alignment: .topLeading)
        .offset(x: rect.minX * zoom, y: rect.minY * zoom)
        .allowsHitTesting(false)
        .animation(.interactiveSpring(duration: 0.12), value: rect)
    }
}

// MARK: - Resizing by the edges

/// An edge or corner of a frame. Anywhere along an edge is live for resizing, not just the dots.
enum ResizeZone: CaseIterable {
    case nw, n, ne, e, se, s, sw, w

    var unit: CGPoint {
        switch self {
        case .nw: CGPoint(x: 0, y: 0); case .n: CGPoint(x: 0.5, y: 0); case .ne: CGPoint(x: 1, y: 0)
        case .e: CGPoint(x: 1, y: 0.5); case .se: CGPoint(x: 1, y: 1); case .s: CGPoint(x: 0.5, y: 1)
        case .sw: CGPoint(x: 0, y: 1); case .w: CGPoint(x: 0, y: 0.5)
        }
    }

    var edges: IssueStore.Edges {
        switch self {
        case .nw: [.left, .top]; case .n: [.top]; case .ne: [.right, .top]; case .e: [.right]
        case .se: [.right, .bottom]; case .s: [.bottom]; case .sw: [.left, .bottom]; case .w: [.left]
        }
    }

    var horizontal: Bool { edges.contains(.left) || edges.contains(.right) }
    var vertical: Bool { edges.contains(.top) || edges.contains(.bottom) }

    /// The same zone with its vertical part dropped, for frames whose height isn't the editor's to set.
    var widthOnly: ResizeZone? {
        switch self {
        case .nw, .w, .sw: .w
        case .ne, .e, .se: .e
        case .n, .s: nil
        }
    }

    /// The same zone with its horizontal part dropped (an upright line in the component editor).
    var heightOnly: ResizeZone? {
        switch self {
        case .nw, .n, .ne: .n
        case .sw, .s, .se: .s
        case .e, .w: nil
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .nw: .topLeft; case .n: .top; case .ne: .topRight; case .e: .right
            case .se: .bottomRight; case .s: .bottom; case .sw: .bottomLeft; case .w: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        default: return .crosshair
        }
    }

    /// The zone under a point, for a frame in the same coordinates. The whole edge is live `reach` on either side
    /// of the line; a corner reaches a little further so it's easy to catch. Inside or outside that: nil.
    static func at(_ p: CGPoint, in f: CGRect, reach: CGFloat = 8, corner: CGFloat = 12) -> ResizeZone? {
        let dl = p.x - f.minX, dr = f.maxX - p.x, dt = p.y - f.minY, db = f.maxY - p.y
        guard dl >= -reach, dr >= -reach, dt >= -reach, db >= -reach else { return nil }
        let l = abs(dl) <= corner, r = abs(dr) <= corner, t = abs(dt) <= corner, b = abs(db) <= corner
        if l && t { return .nw }
        if r && t { return .ne }
        if r && b { return .se }
        if l && b { return .sw }
        if abs(dl) <= reach { return .w }
        if abs(dr) <= reach { return .e }
        if abs(dt) <= reach { return .n }
        if abs(db) <= reach { return .s }
        return nil
    }
}

/// The edges being pulled, drawn heavier so it's clear what the pointer has hold of.
struct EdgeHighlight: View {
    let zone: ResizeZone
    let size: CGSize

    var body: some View {
        Path { p in
            let e = zone.edges
            if e.contains(.top) { p.move(to: .zero); p.addLine(to: CGPoint(x: size.width, y: 0)) }
            if e.contains(.bottom) { p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: size.height)) }
            if e.contains(.left) { p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: size.height)) }
            if e.contains(.right) { p.move(to: CGPoint(x: size.width, y: 0)); p.addLine(to: CGPoint(x: size.width, y: size.height)) }
        }
        .stroke(Color(nsColor: .controlAccentColor), style: StrokeStyle(lineWidth: 3, lineCap: .square))
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

enum ResizeMath {
    /// Move the edges in `zone` of `start` by a pointer delta, keeping the frame at least `minSize`.
    static func resize(_ start: CGRect, _ zone: ResizeZone, dx: CGFloat, dy: CGFloat, min minSize: CGSize) -> CGRect {
        var r = start
        let e = zone.edges
        if e.contains(.left) { r.origin.x = Swift.min(start.minX + dx, start.maxX - minSize.width); r.size.width = start.maxX - r.minX }
        if e.contains(.right) { r.size.width = Swift.max(minSize.width, start.width + dx) }
        if e.contains(.top) { r.origin.y = Swift.min(start.minY + dy, start.maxY - minSize.height); r.size.height = start.maxY - r.minY }
        if e.contains(.bottom) { r.size.height = Swift.max(minSize.height, start.height + dy) }
        return r
    }
}
