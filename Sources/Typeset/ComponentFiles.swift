import AppKit
import SwiftUI
import UniformTypeIdentifiers

// `.typesetcomponent` files (phase 6): one component and its version history, as JSON. File › New Component,
// Save Component As… and Import Component…, the sidebar's Edit… and Add to Library…, and the Library window's
// Components tab all come through here. A component file saved or imported is noted in the library, and the
// sidebar's Components section lists the library's components.

enum ComponentFiles {
    static var fileType: UTType { UTType(filenameExtension: BuiltInComponents.fileExtension, conformingTo: .data) ?? .data }

    static func read(_ url: URL) throws -> Component {
        try IssueStore.decoder().decode(Component.self, from: Data(contentsOf: url))
    }

    static func write(_ c: Component, to url: URL) throws {
        try IssueStore.encoder().encode(c).write(to: url, options: .atomic)
    }

    /// The library the components come from: the user's, or a self-test's own (`testLibrary`). The self-tests
    /// never read the user's library.
    nonisolated(unsafe) static var testLibrary: Library?
    static var library: Library? {
        if let testLibrary { return testLibrary }
        return CommandLine.arguments.contains("--selftest") ? nil : Library.shared
    }

    /// The library's component files that can be read, each read once per change to the file.
    nonisolated(unsafe) private static var cache: [String: (date: Date, component: Component?)] = [:]
    static func libraryFiles() -> [(url: URL, component: Component)] {
        guard let library else { return [] }
        return library.entries.filter { $0.kind == .component }.compactMap { e in
            // the path first (cheap: the sidebar asks on every draw); the bookmark only when the file has moved
            let url = FileManager.default.fileExists(atPath: e.path) ? URL(fileURLWithPath: e.path) : library.location(of: e) ?? URL(fileURLWithPath: e.path)
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if let c = cache[url.path], c.date == date { return c.component.map { (url, $0) } }
            let c = try? read(url)
            cache[url.path] = (date, c)
            return c.map { (url, $0) }
        }
    }

    /// The library file a component is saved in, if any (the one opened most recently, if it's in two).
    static func fileURL(for id: Component.ID) -> URL? {
        let order = library?.entries(.component).map(\.path) ?? []
        return libraryFiles().filter { $0.component.id == id }
            .min { (order.firstIndex(of: $0.url.path) ?? .max) < (order.firstIndex(of: $1.url.path) ?? .max) }?.url
    }

    /// Writes a component file and notes it in the library, with a thumbnail of its newest version.
    static func save(_ c: Component, to url: URL) throws {
        try write(c, to: url)
        library?.note(url, kind: .component, thumbnail: c.latest.map { ComponentThumbnail.image($0, height: 120) })
    }

    /// Import Component…: reads the file and adds it to the library, so the sidebar offers it. Throws when the
    /// file isn't a component Typeset can read.
    @discardableResult
    static func importComponent(_ url: URL) throws -> Component {
        let c = try read(url)
        guard !c.versions.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        library?.note(url, kind: .component, thumbnail: c.latest.map { ComponentThumbnail.image($0, height: 120) })
        return c
    }

    static func savePanel(_ name: String, title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [fileType]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}

// MARK: - the editor's files

extension ComponentEditor {
    /// Save (⌘S in the editor): the draft becomes a new version and the file is written; a component with no file
    /// yet (new, shipped with the app, or only in an issue) asks where first. Nothing is saved if that's cancelled.
    func saveCommand() {
        let url = fileURL ?? ComponentFiles.fileURL(for: id)
        guard let url = url ?? ComponentFiles.savePanel(name, title: "Save Component") else { return }
        save(to: url)
    }

    /// Save Component As…: the component, with the draft as a new version if it's edited, in a file of your choosing.
    func saveAsCommand() {
        guard let url = ComponentFiles.savePanel(name, title: "Save Component As") else { return }
        save(to: url)
    }

    /// Makes the draft a version (if it's new or edited) and writes the whole history to `url`.
    @discardableResult
    func save(to url: URL) -> Bool {
        let wasEdited = isEdited
        let before = savedState
        if wasEdited { saveVersion() }
        do {
            try ComponentFiles.save(componentForSaving, to: url)
            fileURL = url
            return true
        } catch {
            if wasEdited { savedState = before }
            ComponentFiles.alert("“\(name)” couldn't be saved", error.localizedDescription)
            return false
        }
    }
}

// MARK: - the windows

/// The open component editors, one window each. Opening a component that's already open brings its window up.
@MainActor
@Observable
final class ComponentEditorWindows: NSObject, NSWindowDelegate {
    static let shared = ComponentEditorWindows()

    private(set) var editors: [ComponentEditor] = []
    /// The editor whose window is key: File › Save and Save Component As… go to it.
    private(set) var keyEditor: ComponentEditor?
    @ObservationIgnored private var windows: [ObjectIdentifier: NSWindow] = [:]

    func window(for e: ComponentEditor) -> NSWindow? { windows[ObjectIdentifier(e)] }

    /// Opens an editor in its own window (or brings up the one already open on that component, showing the
    /// version asked for if it's another: opened as from the history, so Undo goes back). Returns the editor shown.
    @discardableResult
    func open(_ e: ComponentEditor, store: IssueStore?) -> ComponentEditor {
        if let open = editors.first(where: { $0.id == e.id && $0.fileURL == e.fileURL }) {
            if let v = e.requestedVersion, v != open.base, open.versions.contains(where: { $0.number == v }) { open.openVersion(v) }
            window(for: open)?.makeKeyAndOrderFront(nil)
            return open
        }
        if let store { e.facts = store.issue }
        editors.append(e)
        guard !CommandLine.arguments.contains("--selftest") else { return e }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = e.name
        w.subtitle = "Component"
        w.contentViewController = NSHostingController(rootView: ComponentEditorView().environment(e).tint(Theme.brandSolid))
        w.delegate = self
        w.setFrameAutosaveName("ComponentEditor")
        windows[ObjectIdentifier(e)] = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        return e
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor(of: window)?.undoManager
    }

    func windowDidBecomeKey(_ n: Notification) { keyEditor = (n.object as? NSWindow).flatMap(editor(of:)) }
    func windowDidResignKey(_ n: Notification) {
        if let w = n.object as? NSWindow, keyEditor === editor(of: w) { keyEditor = nil }
        // the mouse-up won't come to a window that isn't key (rule 6)
        if let w = n.object as? NSWindow, let e = editor(of: w), e.pointer.isActive { e.pointerCancelled() }
    }

    /// Closing with unsaved changes asks Save / Don't Save / Cancel.
    func windowShouldClose(_ w: NSWindow) -> Bool {
        guard let e = editor(of: w), e.isEdited, !e.draft.elements.isEmpty || e.base != nil else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(e.name)”?"
        a.informativeText = "Saving makes them a new version of the component."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            e.saveCommand()
            return !e.isEdited
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let e = editor(of: w) else { return }
        windows[ObjectIdentifier(e)] = nil
        editors.removeAll { $0 === e }
        if keyEditor === e { keyEditor = nil }
    }

    private func editor(of w: NSWindow) -> ComponentEditor? {
        editors.first { windows[ObjectIdentifier($0)] === w }
    }

    /// The self-tests close what they opened.
    func closeAll() { editors.removeAll(); keyEditor = nil }
}

// MARK: - the issue's side

extension IssueStore {
    /// File › New Component: an empty component in a new editor window, with the page's columns.
    @MainActor
    @discardableResult
    func newComponentCommand() -> ComponentEditor {
        let e = ComponentEditor.newComponent(pageColumns: issue.layout?.columns ?? grid.columns)
        ComponentEditorWindows.shared.open(e, store: self)
        return e
    }

    /// Edit… on a component (the sidebar, the Library window): the editor, at the version picked (the newest
    /// by default), sitting where the component is placed in this issue if it is.
    @MainActor
    @discardableResult
    func editComponent(_ id: Component.ID, version: Int? = nil) -> ComponentEditor? {
        guard let c = catalogComponent(id) else { return nil }
        let placed = (issue.layout?.pages ?? []).lazy.flatMap(\.components).first { $0.component == id }
        let e = ComponentEditor(component: c, version: version, fileURL: ComponentFiles.fileURL(for: id),
                                origin: placed.map { CGPoint(x: $0.frame.x, y: $0.frame.y) }, pageColumns: issue.layout?.columns ?? grid.columns)
        return ComponentEditorWindows.shared.open(e, store: self)
    }

    /// Opens a component file in the editor (the Library window's Components tab, a double-clicked file).
    @MainActor
    @discardableResult
    func editComponentFile(_ url: URL) -> ComponentEditor? {
        do {
            let c = try ComponentFiles.read(url)
            ComponentFiles.library?.note(url, kind: .component)
            let e = ComponentEditor(component: c, fileURL: url, pageColumns: issue.layout?.columns ?? grid.columns)
            return ComponentEditorWindows.shared.open(e, store: self)
        } catch {
            ComponentFiles.alert("“\(url.deletingPathExtension().lastPathComponent)” can't be opened", "It isn't a component Typeset can read.")
            return nil
        }
    }

    /// A file double-clicked in the Finder: an issue opens as an issue, a component in the editor.
    @MainActor
    func openFromFinder(_ url: URL) {
        if url.pathExtension == BuiltInComponents.fileExtension { editComponentFile(url) } else { openPrompting(url) }
    }

    /// File › Import Component…: a component file into the library, so the sidebar lists it for placing.
    @MainActor
    func importComponentCommand() {
        guard let url = ComponentFiles.openPanel(title: "Import Component") else { return }
        do { try ComponentFiles.importComponent(url) } catch {
            ComponentFiles.alert("“\(url.deletingPathExtension().lastPathComponent)” can't be imported", "It isn't a component Typeset can read.")
        }
    }

    /// Add to Library…: a component that's only in this issue, saved as a file (every version the issue has of
    /// it) and noted in the library.
    @MainActor
    func addToLibraryCommand(_ id: Component.ID) {
        guard let c = catalogComponent(id), let url = ComponentFiles.savePanel(c.name, title: "Add “\(c.name)” to Library") else { return }
        do { try ComponentFiles.save(c, to: url) } catch {
            ComponentFiles.alert("“\(c.name)” couldn't be saved", error.localizedDescription)
        }
    }

    /// Whether a component is only in this issue: not shipped with the app and not in the library.
    func isInIssueOnly(_ id: Component.ID) -> Bool {
        !BuiltInComponents.all.contains { $0.id == id } && !Self.libraryComponents().contains { $0.id == id }
            && issue.componentVersions.contains { $0.id == id }
    }
}

// MARK: - the File menu

/// File › New Component, Import Component… and Save Component As… (for the editor in front).
struct ComponentFileCommands: View {
    let store: IssueStore
    var body: some View {
        Button("New Component") { store.newComponentCommand() }
        Button("Import Component…") { store.importComponentCommand() }
    }
}

struct SaveComponentAsCommand: View {
    var body: some View {
        let key = ComponentEditorWindows.shared.keyEditor
        Button("Save Component As…") { key?.saveAsCommand() }
            .disabled(key == nil)
    }
}
