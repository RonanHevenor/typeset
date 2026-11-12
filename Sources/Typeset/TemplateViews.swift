import SwiftUI

// The template editor's own controls (phase 8): its toolbar, the page thumbnails' menu (add, move, remove), and
// the placed component's Duplicate on All (Inside) Pages. The canvas is the Pages canvas, with only components on
// it: they're placed, clicked, dragged and resized through the same hit test and pointer state machine.

/// The template editor's toolbar: zoom, guides, Add Page and the inspector. No steps, no shuffle, no export.
struct TemplateToolbar: ToolbarContent {
    @Environment(IssueStore.self) private var store
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Template").font(.headline).foregroundStyle(.secondary)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { store.zoom = (store.zoom / 1.25).clamped(0.25, 2) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                Button { store.zoom = (store.zoom * 1.25).clamped(0.25, 2) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            }
            Toggle(isOn: Binding(get: { store.showGuides }, set: { store.showGuides = $0 })) {
                Label("Guides", systemImage: "rectangle.split.3x1")
            }
            .help("Show margins and columns")
            Button { store.addPage() } label: { Label("Add Page", systemImage: "plus.rectangle.portrait") }
                .help("Add a page at the end; components marked to repeat go on it")
            Button { store.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show the components to place (⌥⌘I)")
        }
    }
}

/// A page thumbnail's menu in the template editor.
struct TemplatePageMenu: View {
    @Environment(IssueStore.self) private var store
    let index: Int
    let count: Int
    var body: some View {
        Button("Add Page After") { store.addPage(after: index) }
        Divider()
        Button("Move Up") { store.movePage(index, to: index - 1) }.disabled(index == 0)
        Button("Move Down") { store.movePage(index, to: index + 1) }.disabled(index >= count - 1)
        Divider()
        Button("Remove Page", role: .destructive) { store.removeTemplatePage(index) }.disabled(count < 2)
    }
}

/// On a placed component's right-click menu: copy it to every page, or every inside page, and mark it to repeat.
struct RepeatMenuItems: View {
    @Environment(IssueStore.self) private var store
    let placed: PlacedComponent
    var body: some View {
        Divider()
        Button("Duplicate on All Pages") { store.duplicateOnAllPages(placed.id, inside: false) }
        Button("Duplicate on All Inside Pages") { store.duplicateOnAllPages(placed.id, inside: true) }
        if let r = placed.repeats {
            Button("Don't Repeat on New Pages") { store.stopRepeating(placed.id) }
                .help(r == .allPages ? "Repeats on every page added" : "Repeats on every inside page added")
        }
    }
}
