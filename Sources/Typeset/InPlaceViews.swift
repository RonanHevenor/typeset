import SwiftUI
import AppKit

// The views for phase 7: the outlines of a multiple selection and the marquee, the menu and inspector section for
// several items, and the in-place editor (phase 6's canvas, tools and inspector over the page, with Done, Save as
// New Version and Revert). Like the other handles these only draw; presses go to the store's pointer state machine,
// or, in place, to the editor's.

/// A multiple selection's outlines, and while a marquee is drawn, the marquee and what it would take. Takes no clicks.
struct MultiSelectionOverlay: View {
    @Environment(IssueStore.self) private var store
    let index: Int

    var body: some View {
        let z = store.zoom
        let items = store.hitItems(on: index)
        let accent = Color(nsColor: .controlAccentColor)
        let marquee = store.pointer.phase == .marquee && store.pointer.page == index ? store.pointer.marquee : nil
        let selected: Set<LayoutSelection> = store.isMultiSelection && store.selectionPage == index ? store.selectionSet : []
        let taking: Set<LayoutSelection> = marquee.map { store.enclosed(by: $0, on: index) } ?? []
        ZStack(alignment: .topLeading) {
            ForEach(items.filter { selected.contains($0.selection) || taking.contains($0.selection) }, id: \.id) { item in
                Rectangle()
                    .strokeBorder(accent, lineWidth: selected.contains(item.selection) ? 2 : 1.25)
                    .frame(width: item.shape.width * z, height: item.shape.height * z)
                    .offset(x: item.shape.minX * z, y: item.shape.minY * z)
            }
            if let m = marquee {
                Rectangle()
                    .fill(accent.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: m.width * z, height: m.height * z)
                    .offset(x: m.minX * z, y: m.minY * z)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The right-click menu for an item of a multiple selection: it acts on the whole set.
struct MultiSelectionMenu: View {
    @Environment(IssueStore.self) private var store

    var body: some View {
        let n = store.selectionSet.count
        Button("Make Component…") { store.makeComponentCommand() }
        Divider()
        Button("Delete \(n) Items", role: .destructive) { store.deleteSet() }
    }
}

/// The inspector's Selection section with several items selected.
struct MultiSelectionControls: View {
    @Environment(IssueStore.self) private var store

    var body: some View {
        let items = store.selectionSet
        VStack(alignment: .leading, spacing: 8) {
            Text("\(items.count) items").font(.headline)
            Text(items.map { store.name(of: $0) }.sorted().joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Text("Drag any of them to move them all; the arrow keys nudge them, Delete removes them. ⇧-click adds or takes out an item.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Make Component…") { store.makeComponentCommand() }
                Button("Delete", role: .destructive) { store.deleteSet() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// A custom placement's commands, for its right-click menu and the inspector: Save as New Version, Revert to vN.
struct CustomComponentItems: View {
    @Environment(IssueStore.self) private var store
    let placed: PlacedComponent

    var body: some View {
        if placed.custom != nil {
            Button("Save as New Version") { store.saveCustomAsNewVersion(placed.id) }
                .help("Makes this copy the component's next version, for future use")
            Button("Revert to v\(placed.version)") { store.revertCustom(placed.id) }
                .help("Drops the changes made in place")
        }
    }
}

// MARK: - the in-place editor

/// The editor's canvas over the page it edits on, at the pages' zoom: it takes every press on that page.
struct InPlaceCanvas: NSViewRepresentable {
    @Environment(IssueStore.self) private var store
    let editor: ComponentEditor
    let key: Int

    func makeNSView(context: Context) -> EditorCanvasView {
        let v = EditorCanvasView()
        v.inPlace = true
        v.editor = editor
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }       // Delete, arrows and Escape go to the editor
        return v
    }

    func updateNSView(_ v: EditorCanvasView, context: Context) {
        v.editor = editor
        v.onLeave = { [weak store] in store?.leaveInPlace() }
        v.needsDisplay = true
    }
}

/// The in-place canvas, in a view of its own so only it draws again as the editor changes.
struct InPlaceLayer: View {
    let editor: ComponentEditor
    /// The pages' zoom, which the editor follows.
    let zoom: CGFloat
    var body: some View {
        InPlaceCanvas(editor: editor, key: editor.drawKey)
            .onChange(of: zoom, initial: true) { _, z in if editor.zoom != z { editor.zoom = z } }
    }
}

/// The tools along the top of the canvas while a component is edited in place, with Done.
struct InPlaceBar: View {
    @Environment(IssueStore.self) private var store
    let edit: InPlaceEdit

    var body: some View {
        HStack(spacing: 0) {
            EditorToolbar(inPlace: true)
            Divider().frame(height: 18)
            HStack(spacing: 8) {
                Text("Editing \(edit.editor.name) in place").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Button("Done") { store.leaveInPlace() }
                    .help("Keep the changes on this page: the component reads “\(edit.editor.name) custom”")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
        }
        .environment(edit.editor)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The inspector while a component is edited in place: phase 6's, with what's open and how to leave it on top.
struct InPlaceInspector: View {
    @Environment(IssueStore.self) private var store
    let edit: InPlaceEdit

    var body: some View {
        EditorInspector(inPlace: true) {
            Section("In Place") {
                let label = store.placedComponent(edit.placed).map { store.componentLabel($0.placed) } ?? edit.editor.name
                Text("Editing \(label) on page \(edit.page + 1). The rest of the paper waits until you're done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Done") { store.leaveInPlace() }
                Text("Done keeps the changes on this page only (“\(edit.editor.name) custom”). Then Save as New Version or Revert, on its right-click menu or here.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(edit.editor)
    }
}
