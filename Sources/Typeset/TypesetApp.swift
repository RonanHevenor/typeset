import SwiftUI
import AppKit


/// Files opened from the Finder (a .typeset issue double-clicked) before or after the window is up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var open: ((URL) -> Void)? { didSet { if let open { pending.forEach(open); pending = [] } } }
    private var pending: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where [IssueFile.fileExtension, IssueTemplate.fileExtension, BuiltInComponents.fileExtension].contains(url.pathExtension) {
            if let open { open(url) } else { pending.append(url) }
        }
    }
}

struct TypesetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = IssueStore(backgroundFits: true)

    init() { FontLoader.registerBundledFonts() }

    var body: some Scene {
        WindowGroup("Typeset") {
            ContentView()
                .environment(store)
                .tint(Theme.brandSolid)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { delegate.open = { [store] url in DispatchQueue.main.async { store.openFromFinder(url) } } }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(after: .appSettings) { SetupCommand() }
            CommandGroup(replacing: .newItem) {
                Button("New Issue") { store.newIssueCommand() }
                    .keyboardShortcut("n")
                Button("New Article") { store.newArticle() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Template") { store.newTemplateCommand() }
                ComponentFileCommands(store: store)
                Divider()
                Button("Open…") { store.openCommand() }
                    .keyboardShortcut("o")
                OpenRecentMenu(store: store)
                LibraryCommand()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { if let e = ComponentEditorWindows.shared.keyEditor { e.saveCommand() } else { store.saveCommand() } }
                    .keyboardShortcut("s")
                Button("Save As…") { store.saveAsCommand() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                SaveComponentAsCommand()
                Button("Revert to Saved") { store.revertCommand() }
                    .disabled(!store.canRevert)
                Button("Save as Template…") { store.saveAsTemplateCommand() }
                    .disabled(store.isEditingTemplate || store.issue.layout == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste as New Article") { store.pasteArticle() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                if PolyWeb.enabled {
                    Button("Add Article from Link…") { store.addFromLinkPrompt() }
                        .keyboardShortcut("l")
                        .disabled(store.webWork != nil)
                    Button("Update Stories from Website") { store.updateFromWebsite() }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                        .disabled(store.webWork != nil || store.issue.articles.isEmpty)
                }
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Issue as JSON…") { store.exportIssue() }
            }
            TextFormattingCommands()
            CommandMenu("Issue") {
                Button(store.issue.stage == .priority ? "Generate Paper" : "Done Adding Stories") { store.advance() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.issue.stage == .pages)
                Button("Shuffle Layout") { store.generate() }
                    .disabled(store.issue.stage != .pages)
                Button("Add Page") { store.addPage() }
                    .disabled(store.issue.layout == nil)
                Button("Clear All Pages") { store.clearPages() }
                    .disabled(store.issue.layout == nil)
                Button("Fill Holes on This Page") { if let p = store.focusedPage { store.fillHoles(on: p) } }
                    .disabled(store.focusedPage == nil)
                Divider()
                Button("Dismiss Story to Sidebar") {
                    if let id = store.selectedBlock, let (_, b) = store.block(id) { store.parkStory(b.article) }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(store.selectedBlock == nil)
                Divider()
                Button("Fit Height to Text") { if let id = store.selectedBlock { store.fitBlock(id) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(store.selectedBlock == nil)
                Button("Fill Down") { if let id = store.selectedBlock { store.fillDown(id) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Fill Space") { if let id = store.selectedBlock { store.fillSpace(id) } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.selectedBlock == nil)
                Divider()
                Button("Export PDF…") { store.exportPDF() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.issue.layout == nil)
                Button("Export for InDesign…") { store.exportIDML() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(store.issue.layout == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { store.zoom = (store.zoom * 1.25).clamped(0.25, 2) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { store.zoom = (store.zoom / 1.25).clamped(0.25, 2) }
                    .keyboardShortcut("-")
                Button("Zoom to Fit") { store.zoomToFit() }
                    .keyboardShortcut("0")
                Button("Actual Size") { store.zoom = 1 }
                    .keyboardShortcut("1")
                Button("Show Guides") { store.showGuides.toggle() }
                    .keyboardShortcut(";")
                Button("Inspector") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }
        Window("Library", id: "library") {
            LibraryView()
                .environment(store)
                .tint(Theme.brandSolid)
        }
        .defaultSize(width: 640, height: 520)
        Window("Set Up Typeset", id: "setup") {
            SetupView()
                .tint(Theme.brandSolid)
        }
        .windowResizability(.contentSize)
    }
}
