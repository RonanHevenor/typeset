import SwiftUI
import AppKit

// The views for components on the page (phase 5): the selection box over a placed component, its right-click
// menu, its controls in the inspector, and the sidebar's Components section. Like the other handles, the box only
// draws: the page's pointer view takes every press and asks the hit test (CanvasHitTest), so clicking, dragging
// and resizing a component go through the store's pointer state machine.

/// The selected component's box: outline, label ("Header v3", "Header custom"), handles and the edge under the
/// pointer; while it's dragged, a heavier outline. Takes no clicks.
struct ComponentHandle: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let placed: PlacedComponent
    let frame: CGRect

    var body: some View {
        let z = store.zoom
        let pad = CanvasHitTest.reach
        let size = CGSize(width: frame.width * z, height: frame.height * z)
        let selected = store.canvasSelection == .component(placed.id)
        let pointer = store.pointer
        let mine = pointer.item == .component(placed.id)
        let dragging = mine && pointer.isDragging
        let zone: ResizeZone? = mine && (pointer.phase == .resizing || pointer.phase == .pressed) ? pointer.hit?.edge
            : selected && !pointer.isActive ? store.hoverZone : nil
        ZStack(alignment: .topLeading) {
            if selected || dragging {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(pad)
                if let t = pointer.frame, mine, pointer.phase == .pullingFill || pointer.phase == .cropping {
                    // the frame whose content is being carried or slid
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: t.rect.width * z, height: t.rect.height * z)
                        .offset(x: pad + (t.rect.minX - frame.minX) * z, y: pad + (t.rect.minY - frame.minY) * z)
                }
            }
            if selected, !dragging {
                Text(store.componentLabel(placed))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .fixedSize()
                    .offset(x: pad, y: pad - 22)
                if let live = zone {
                    EdgeHighlight(zone: live, size: size).padding(pad)
                }
                ForEach(ResizeZone.allCases, id: \.self) { c in
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
        .offset(x: frame.minX * z - pad, y: frame.minY * z - pad)
        .allowsHitTesting(false)
    }
}

/// The right-click menu for a placed component, with the frame under the pointer's own commands.
struct ComponentMenu: View {
    @Environment(IssueStore.self) private var store
    let pageIndex: Int
    let placed: PlacedComponent
    let frame: IssueStore.FrameTarget?

    var body: some View {
        if let t = frame, store.fill(of: t) != nil {
            if t.frame.type == .image, store.fill(of: t)?.focus != CGPoint(x: 0.5, y: 0.5) {
                Button("Center the Crop") { store.centerCrop(t) }
            }
            Button("Clear \(t.frame.type.title) Frame") { store.clearFrame(t) }
            Divider()
        }
        let versions = store.versions(for: placed)
        Menu("Switch Version…") {
            ForEach(versions, id: \.self) { n in
                Button(n == placed.version && placed.custom == nil ? "v\(n) (this one)" : "v\(n)") { store.confirmSwitchVersion(placed.id, to: n) }
                    .disabled(n == placed.version && placed.custom == nil)
            }
        }
        .disabled(versions.count < 2 && placed.custom == nil)
        Button("Edit in Place") { store.enterInPlace(placed.id) }
        CustomComponentItems(placed: placed)                             // InPlaceViews.swift (phase 7)
        Button("Edit Component…") { store.editComponent(placed.component, version: placed.version) }
        RepeatMenuItems(placed: placed)                                  // IssueStore+Templates.swift (phase 8)
        Divider()
        Button("Remove from Page", role: .destructive) { store.removeComponent(placed.id) }
    }
}

/// The inspector's Selection section for a placed component: its label, size, frames and what fills them.
struct ComponentSelectionControls: View {
    @Environment(IssueStore.self) private var store
    let id: PlacedComponent.ID

    var body: some View {
        if let (_, p) = store.placedComponent(id) {
            let r = p.frame.rect
            VStack(alignment: .leading, spacing: 10) {
                Text(store.componentLabel(p)).font(.headline)
                Text(String(format: "%.1f × %.1f in", r.width / 72, r.height / 72))
                    .font(.caption).foregroundStyle(.secondary)
                let targets = store.frameTargets(id)
                if !targets.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(targets, id: \.frame.id) { t in
                            HStack(spacing: 6) {
                                Text(t.frame.type.title + (t.frame.link.map { " \($0)" } ?? ""))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 104, alignment: .leading)
                                if let f = store.fill(of: t) {
                                    Text(store.describe(f)).font(.caption).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Button { store.clearFrame(t) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .help("Clear this frame; what it held goes back to the sidebar")
                                } else {
                                    Text("Empty").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Text("Drop a story, photo or ad on a frame to fill it. ⌥-drag a filled frame off the component to clear it; ⌘-drag a picture to slide its crop.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    let versions = store.versions(for: p)
                    Menu("Switch Version…") {
                        ForEach(versions, id: \.self) { n in
                            Button("v\(n)") { store.confirmSwitchVersion(id, to: n) }
                                .disabled(n == p.version && p.custom == nil)
                        }
                    }
                    .fixedSize()
                    .disabled(versions.count < 2 && p.custom == nil)
                    Button("Remove from Page", role: .destructive) { store.removeComponent(id) }
                }
                .controlSize(.small)
                HStack {
                    Button("Edit in Place") { store.enterInPlace(id) }
                        .help("Or double-click it on the page")
                    CustomComponentItems(placed: p)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }
}

/// The sidebar's Components section, under Ads & Graphics: one row per component, to drag onto a page.
struct ComponentsSection: View {
    @Environment(IssueStore.self) private var store
    let pageCount: Int

    var body: some View {
        let catalog = store.componentCatalog()
        Section {
            ForEach(catalog) { c in ComponentRow(component: c, pageCount: pageCount) }
        } header: {
            Label("Components", systemImage: "square.on.square.dashed")
        } footer: {
            Text("Drag one onto a page to place it, at the version picked here. Drop stories, photos and ads on its frames to fill them. Right-click one to edit it.")
                .foregroundStyle(.secondary)
        }
    }
}

struct ComponentRow: View {
    @Environment(IssueStore.self) private var store
    let component: Component
    let pageCount: Int
    /// The version a drag places; nil is the latest.
    @State private var picked: Int?

    var body: some View {
        let latest = component.latest?.number ?? 1
        let n = picked.flatMap { component.version($0) != nil ? $0 : nil } ?? latest
        let runs = store.componentRuns(component.id)
        let thumb = component.version(n).map { ComponentThumbnail.image($0, height: 30) }
        let inLibrary = BuiltInComponents.all.contains { $0.id == component.id } || IssueStore.libraryComponents().contains { $0.id == component.id }
        HStack(spacing: 8) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 64, height: 30)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            .overlay(RowDragSource(item: .component(component.id, n), title: "\(component.name) v\(n)", image: thumb) {
                if let (page, p) = (store.issue.layout?.pages ?? []).enumerated().lazy.compactMap({ i, pg in pg.components.first { $0.component == component.id }.map { (i, $0) } }).first {
                    store.canvasSelection = .component(p.id); store.focusedPage = page
                }
            })
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name).font(.callout.weight(.semibold))
                Text(runs.isEmpty ? (inLibrary ? "Not in this issue" : "In this issue only") : runs.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Picker("Version", selection: Binding(get: { n }, set: { picked = $0 == latest ? nil : $0 })) {
                ForEach(component.versions.map(\.number), id: \.self) { v in Text(v == latest ? "v\(v) (latest)" : "v\(v)").tag(v) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("The version a drag from here places")
        }
        .contextMenu {
            Button("Edit…") { store.editComponent(component.id, version: n) }
            if !inLibrary {
                Button("Add to Library…") { store.addToLibraryCommand(component.id) }
            }
            Divider()
            Menu("Place on Page") {
                ForEach(0..<pageCount, id: \.self) { p in
                    Button(p == 0 ? "Front Page" : "Page \(p + 1)") { store.placeComponent(component.id, version: n, on: p) }
                }
            }
        }
    }
}

/// A small picture of a component version, for its sidebar row: shapes, lines, preset text and art as placed,
/// and every frame as its empty placeholder.
enum ComponentThumbnail {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(_ v: ComponentVersion, height: CGFloat) -> NSImage {
        let key = "\(v.hashValue)|\(height)"
        if let c = cache[key] { return c }
        let k = height / max(1, v.height)
        // a very wide component (the Folio) is drawn at the row's width instead
        let scale = min(k, 128 / max(1, v.width))
        let size = NSSize(width: max(1, v.width * scale), height: max(1, v.height * scale))
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            for e in v.elements {
                switch e {
                case .line(let l):
                    let p = NSBezierPath(); p.move(to: l.from); p.line(to: l.to); p.lineWidth = max(l.width, 1 / scale)
                    l.color.nsColor.setStroke(); p.stroke()
                case .rect(let s):
                    if let f = s.fill { f.nsColor.setFill(); s.box.rect.fill() }
                    if let k = s.stroke { k.nsColor.setStroke(); let p = NSBezierPath(rect: s.box.rect); p.lineWidth = s.strokeWidth; p.stroke() }
                case .ellipse(let s):
                    let p = NSBezierPath(ovalIn: s.box.rect)
                    if let f = s.fill { f.nsColor.setFill(); p.fill() }
                    if let k = s.stroke { k.nsColor.setStroke(); p.lineWidth = s.strokeWidth; p.stroke() }
                case .text(let t):
                    t.attributed.draw(with: t.box.rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                case .art(let a):
                    NSImage(data: a.data)?.draw(in: a.box.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                case .frame(let f):
                    EmptyFrameArt.draw(f.type, in: f.box.rect)
                }
            }
            return true
        }
        cache[key] = img
        return img
    }
}
