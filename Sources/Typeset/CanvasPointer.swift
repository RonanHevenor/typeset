import SwiftUI
import AppKit

/// The view side of the canvas pointer (phase 2). Each page has one AppKit view (`PageDropView`) that takes every
/// left-button press, move and release over the page and its edge band, turns it into page points and feeds the
/// store's state machine (`Store+Pointer.swift`). The handles over stories and pictures only draw. What's under
/// the pointer always comes from `CanvasHitTest`, so click, hover, cursor, drag start and right-click agree.

/// Where a pointer in window coordinates is, for a drag: over which page (only the part of it that's on screen),
/// or well past the canvas into the inspector.
enum PointerRouting {
    /// A page as it sits in the window: its whole frame at this zoom, and the part of it the canvas shows.
    /// Window coordinates, y up.
    struct PageArea: Equatable {
        var index: Int
        var frame: CGRect
        var visible: CGRect
    }

    /// How far past the canvas's right edge a drag has to go before it counts as over the inspector.
    static let inspectorSlack: CGFloat = 24

    /// The page under `w`, judged only by what's visible (a page scrolled out under the inspector doesn't count,
    /// IB-13); past the canvas's right edge with the inspector open, `.inspector`; anywhere else, the start page
    /// with the point outside it.
    static func location(_ w: CGPoint, pages: [PageArea], canvasMaxX: CGFloat?, inspector: Bool, start: Int, zoom: CGFloat) -> IssueStore.PointerLocation {
        if let a = pages.first(where: { !$0.visible.isEmpty && $0.visible.contains(w) }) {
            return .page(a.index, point(w, in: a.frame, zoom: zoom))
        }
        if inspector, let mx = canvasMaxX, w.x > mx + inspectorSlack { return .inspector }
        let home = pages.first { $0.index == start }
        return .page(start, home.map { point(w, in: $0.frame, zoom: zoom) } ?? CGPoint(x: -1e4, y: -1e4))
    }

    /// A window point in a page's points.
    static func point(_ w: CGPoint, in frame: CGRect, zoom: CGFloat) -> CGPoint {
        CGPoint(x: (w.x - frame.minX) / zoom, y: (frame.maxY - w.y) / zoom)
    }
}

/// What the pages' pointer views share: which item the pointer is over (for the hover outline and the right-click
/// menu), the page views themselves (so a drag can find the page under it), and whether the last change of the
/// focused page came from the pointer (a click doesn't scroll the canvas, IB-2). None of it is drag state: that
/// lives in `store.pointer` only (IB-16).
@Observable
final class CanvasPointerUI {
    struct Hovered: Equatable {
        var page: Int
        var item: LayoutSelection
    }
    /// The item under the pointer, from the hit test: the topmost thing drawn there, or the selected item when
    /// the pointer is on its edge band.
    var hovered: Hovered?

    @ObservationIgnored var views: [Int: WeakPageView] = [:]
    /// The canvas's right edge in window x, from SwiftUI, for when the page view can't find its scroll view.
    @ObservationIgnored var canvasMaxX: CGFloat?
    /// The page the pointer last made the focused page; the canvas doesn't scroll for that change.
    @ObservationIgnored var focusFromPointer: Int?

    struct WeakPageView { weak var view: PageDropView? }

    /// Whether the canvas should scroll to `page` now that it's the focused page: not when the pointer made it so.
    func shouldScroll(to page: Int) -> Bool {
        if focusFromPointer == page { focusFromPointer = nil; return false }
        focusFromPointer = nil
        return true
    }

    /// Run a pointer call, noting whether it moved the focused page.
    func fromPointer(_ store: IssueStore, _ body: () -> Void) {
        let before = store.focusedPage
        body()
        if store.focusedPage != before, let p = store.focusedPage { focusFromPointer = p }
    }

    func setHovered(_ h: Hovered?) { if hovered != h { hovered = h } }

    /// After a nudge, zoom, undo or selection change with the pointer still: the hovered edge, the item and the
    /// cursor are worked out again from the geometry now (IB-8).
    func refresh(_ store: IssueStore) {
        store.refreshHover()
        guard !store.pointer.isActive, let h = store.hover else { return }
        let hit = store.hit(at: h.point, on: h.page)
        setHovered(hit.selection.map { Hovered(page: h.page, item: $0) })
        if NSApp.isActive { hit.cursor.set() }
    }

    /// The pointer's position again, after the canvas scrolled under a still mouse.
    func rehoverAtMouse() {
        for v in views.values.compactMap(\.view) { v.rehoverAtMouse() }
    }

    /// Every page on screen, in window coordinates, for routing a drag.
    func pageAreas(in window: NSWindow?) -> [PointerRouting.PageArea] {
        views.values.compactMap(\.view).filter { $0.window === window }.map { $0.area() }
    }
}

extension IssueStore {
    /// What an item on the canvas is called, for the dashed preview when it's dragged onto another page.
    func name(of sel: LayoutSelection) -> String {
        switch sel {
        case .block(let id):
            return block(id).flatMap { article($0.block.article)?.plainHeadline } ?? "Story"
        case .inset(let id):
            for p in issue.layout?.pages ?? [] {
                guard let i = p.insets.first(where: { $0.id == id }) else { continue }
                switch i.kind {
                case .pullQuote: return "Pull quote"
                case .extra: return extra(i.extra)?.kind.rawValue ?? "Item"
                case .photo: return "Photo"
                }
            }
            return "Item"
        case .component(let id):
            return placedComponent(id).map { componentLabel($0.placed) } ?? "Component"
        }
    }

    /// The help text for a story block under the pointer.
    func helpText(for sel: LayoutSelection?, on page: Int) -> String? {
        guard case .block(let id) = sel, let r = displayPages[safe: page]?.blockResults[id] else { return nil }
        return r.oversetLines > 0 ? "\(r.oversetLines) lines are read online" : "\(r.empty) empty lines"
    }
}

/// The modifier keys of an AppKit event, as the pointer state machine wants them.
extension IssueStore.PointerModifiers {
    init(_ f: NSEvent.ModifierFlags) {
        self = []
        if f.contains(.shift) { insert(.shift) }
        if f.contains(.command) { insert(.command) }
        if f.contains(.option) { insert(.option) }
    }
}

/// The outline of whatever the pointer is over: the shape the hit test uses, so what lights up is what a click
/// would take. Nothing while a gesture runs, and nothing on the selected item (it has its own outline).
struct HoverOutline: View {
    @Environment(IssueStore.self) private var store
    @Environment(CanvasPointerUI.self) private var ui
    let index: Int

    var body: some View {
        if let h = ui.hovered, h.page == index, !store.pointer.isActive, store.canvasSelection != h.item,
           let item = store.hitItems(on: index).first(where: { $0.selection == h.item }) {
            let z = store.zoom
            let accent = Color(nsColor: .controlAccentColor)
            Rectangle()
                .strokeBorder(item.isBlock ? accent.opacity(0.55) : accent, lineWidth: item.isBlock ? 1 : 1.25)
                .frame(width: item.shape.width * z, height: item.shape.height * z)
                .offset(x: item.shape.minX * z, y: item.shape.minY * z)
                .allowsHitTesting(false)
        }
    }
}

/// The right-click menu for a page. Right-clicks pass through the page's pointer view to this layer, and the menu
/// is for the item the hit test puts under the pointer: the same answer a click gets (rule 3).
struct PageMenuArea: View {
    @Environment(CanvasPointerUI.self) private var ui
    let index: Int
    let size: CGSize

    var body: some View {
        let target = ui.hovered.flatMap { $0.page == index ? $0.item : nil }
        Color.clear
            .contentShape(Rectangle())
            .frame(width: size.width, height: size.height)
            .contextMenu { PageItemMenu(index: index, target: target) }
    }
}

struct PageItemMenu: View {
    @Environment(IssueStore.self) private var store
    let index: Int
    let target: LayoutSelection?

    var body: some View {
        let page = store.issue.layout?.pages[safe: index]
        // the frame under the pointer on a component: its own commands (Clear Frame, Center the Crop) join the menu
        let frame = store.hover.flatMap { $0.page == index ? store.frameTarget(at: $0.point, on: index) : nil }
        switch target {
        case let t? where store.isMultiSelection && store.selectionSet.contains(t):
            MultiSelectionMenu()                                 // an item of a multiple selection: the menu is the set's
        case .block(let id):
            if let b = page?.stories.first(where: { $0.id == id }) {
                BlockMenu(pageIndex: index, block: b)
                Divider()
                Button("Make Component…") { store.makeComponentCommand(.block(id)) }
            }
        case .inset(let id):
            if let i = page?.insets.first(where: { $0.id == id }) {
                InsetMenu(pageIndex: index, inset: i)
                Divider()
                Button("Make Component…") { store.makeComponentCommand(.inset(id)) }
            }
        case .component(let id):
            if let c = page?.components.first(where: { $0.id == id }) { ComponentMenu(pageIndex: index, placed: c, frame: frame) }
        case nil:
            EmptyView()
        }
    }
}
