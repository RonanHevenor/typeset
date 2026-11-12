import SwiftUI
import AppKit

/// The Library window (File › Library…, ⇧⌘O): every issue, template and component opened or saved, newest first.
struct LibraryView: View {
    @Environment(IssueStore.self) private var store
    @State private var kind: LibraryEntry.Kind = .issue
    @State private var picked: LibraryEntry.ID?
    private var library: Library { Library.shared }

    var body: some View {
        let rows = library.entries(kind)
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(LibraryEntry.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(10)
            if rows.isEmpty {
                ContentUnavailableView(kind == .issue ? "No issues yet" : "No \(kind.title.lowercased()) yet",
                                       systemImage: "books.vertical",
                                       description: Text(kind == .component ? "Components you save, import or open show up here." : "\(kind.title) you open or save show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(rows, selection: $picked) { e in
                    LibraryRow(entry: e, missing: library.location(of: e) == nil, thumbnail: library.thumbnailImage(e))
                        .tag(e.id)
                        .contextMenu { actions(for: e) }
                }
                .contextMenu(forSelectionType: LibraryEntry.ID.self, menu: { _ in }, primaryAction: { ids in
                    if let id = ids.first, let e = rows.first(where: { $0.id == id }) { open(e) }
                })
            }
            Divider()
            HStack {
                if let id = picked, let e = rows.first(where: { $0.id == id }) {
                    Button("Open") { open(e) }
                    Button("Show in Finder") { showInFinder(e) }
                    Button("Locate…") { locate(e) }
                    Spacer()
                    Button("Remove from Library") { library.remove(e.id); picked = nil }
                } else {
                    Text("Removing an entry leaves its file where it is.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { library.refresh() }
    }

    @ViewBuilder private func actions(for e: LibraryEntry) -> some View {
        Button("Open") { open(e) }
        Button("Show in Finder") { showInFinder(e) }
        Button("Locate…") { locate(e) }
        Divider()
        Button("Remove from Library") { library.remove(e.id); if picked == e.id { picked = nil } }
    }

    private func open(_ e: LibraryEntry) {
        guard let url = library.resolve(e.id) else { locate(e); return }
        if e.kind == .component { store.editComponentFile(url) } else { store.openPrompting(url) }
    }

    private func showInFinder(_ e: LibraryEntry) {
        if let url = library.resolve(e.id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            store.fileAlert("“\(e.name)” isn't where it was", "It was in \(URL(fileURLWithPath: e.path).deletingLastPathComponent().path). Use Locate… to show where it went.")
        }
    }

    private func locate(_ e: LibraryEntry) {
        let panel = NSOpenPanel()
        panel.title = "Locate “\(e.name)”"
        panel.allowedContentTypes = [e.kind == .component ? ComponentFiles.fileType
                                     : .init(exportedAs: e.kind == .template ? IssueTemplate.typeIdentifier : IssueFile.typeIdentifier)]
        panel.directoryURL = URL(fileURLWithPath: e.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.locate(e.id, at: url)
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let missing: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit) }
                else { Rectangle().fill(.white).overlay { Image(systemName: "doc.text").foregroundStyle(.tertiary) } }
            }
            .frame(width: 44, height: 44 * HouseStyle.page.height / HouseStyle.page.width)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .opacity(missing ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body.weight(.medium))
                Text((URL(fileURLWithPath: entry.path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if missing {
                    Text("Missing: use Locate… to show where it went").font(.caption).foregroundStyle(.red)
                } else {
                    Text("Opened \(entry.lastOpened.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

/// File › Open Recent: the system's recent list, as NSDocumentController keeps it.
struct OpenRecentMenu: View {
    let store: IssueStore
    var body: some View {
        let _ = Library.shared.recentsChanged
        Menu("Open Recent") {
            ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { store.openPrompting(url) }
            }
            Divider()
            Button("Clear Menu") {
                NSDocumentController.shared.clearRecentDocuments(nil)
                Library.shared.recentsChanged &+= 1
            }
        }
    }
}

/// File › Library… (⇧⌘O).
struct LibraryCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Library…") { openWindow(id: "library") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}
