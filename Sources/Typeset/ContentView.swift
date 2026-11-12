import SwiftUI

/// The window: three steps — gather the stories, rank them, then the generated pages.
struct ContentView: View {
    @Environment(IssueStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch store.isEditingTemplate ? .pages : store.issue.stage {
            case .stories: StoriesView()
            case .priority: PriorityScreen()
            case .pages: PagesScreen()
            }
        }
        .navigationTitle(store.documentTitle)
        .background(DocumentWindowState(url: store.fileURL, edited: store.isEdited))
        .navigationSubtitle((store.isEdited ? "Edited · " : "") + subtitle)
        .toolbar { toolbar }
        .alert("Couldn't open the saved issue", isPresented: Binding(get: { store.loadProblem != nil }, set: { if !$0 { store.loadProblem = nil } })) {
            Button("OK") { store.loadProblem = nil }
        } message: {
            Text(store.loadProblem ?? "")
        }
        .onAppear { if Setup.shared.shouldOpenOnLaunch { openWindow(id: "setup") } }
    }

    private var subtitle: String {
        if store.isEditingTemplate { return "Template · \(store.issue.layout?.pages.count ?? 0) pages" }
        if store.issue.stage == .pages, let l = store.issue.layout {
            return "\(l.pages.count) pages · \(l.columns) columns · \(Int(l.charsPerLine.rounded())) characters per line"
        }
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"
        return "Vol. \(store.issue.volume) · Ed. \(store.issue.edition) · \(f.string(from: store.issue.date))"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if store.isEditingTemplate {
            TemplateToolbar()                                     // the template editor has no Content or Priority step
        } else {
        ToolbarItem(placement: .navigation) { MissingFontsButton() }
        ToolbarItem(placement: .principal) {
            StepSwitcher(selection: store.issue.stage) { store.go(to: $0) }
            .frame(width: 270)
            .help("Stories, then priority, then pages")
        }
        switch store.issue.stage {
        case .stories: StoriesToolbar()
        case .priority: PriorityToolbar()
        case .pages: PagesToolbar()
        }
        }
    }
}

struct StoriesToolbar: ToolbarContent {
    @Environment(IssueStore.self) private var store
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.pasteArticle() } label: {
                Label("Paste Article", systemImage: "doc.on.clipboard")
            }
            .help("Paste a whole story — headline and byline are detected (⇧⌘V)")
            if PolyWeb.enabled {
                Button { store.addFromLinkPrompt() } label: {
                    Label("Add from Link", systemImage: "link")
                }
                .help("Add a story from its poly.rpi.edu link: text, byline and photos (⌘L)")
                .disabled(store.webWork != nil)
                if let work = store.webWork {
                    ProgressView().controlSize(.small).help(work)
                } else {
                    Button { store.updateFromWebsite() } label: {
                        Label("Update from Website", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Refresh every story's text and photos from poly.rpi.edu (⇧⌘U)")
                    .disabled(store.issue.articles.isEmpty)
                }
            }
            Button { store.newArticle() } label: {
                Label("New Article", systemImage: "square.and.pencil")
            }
            .help("New article (⌘N)")
            Menu {
                ForEach(Extra.Kind.allCases) { k in
                    Button { store.addExtras(k) } label: { Label("\(k.rawValue)…", systemImage: k.symbol) }
                }
            } label: {
                Label("Insert", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Insert an ad, image or graphic that runs on its own")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.advance() } label: {
                Label("Done Adding", systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
            .prominent()
            .help("Done adding stories for now — set their priority next (⌘↩)")
        }
    }
}

struct PriorityToolbar: ToolbarContent {
    @Environment(IssueStore.self) private var store
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { store.advance() } label: {
                Label("Generate Paper", systemImage: "newspaper").labelStyle(.titleAndIcon)
            }
            .prominent()
            .help("Lay out the paper in this order (⌘↩)")
        }
    }
}

struct PagesToolbar: ToolbarContent {
    @Environment(IssueStore.self) private var store
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { store.zoom = (store.zoom / 1.25).clamped(0.25, 2) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                Button { store.zoom = (store.zoom * 1.25).clamped(0.25, 2) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            }
            Toggle(isOn: Binding(get: { store.showGuides }, set: { store.showGuides = $0 })) {
                Label("Guides", systemImage: "rectangle.split.3x1")
            }
            .help("Show margins, columns and overset text")
            Menu {
                Button { store.generate() } label: { Label("Shuffle Paper", systemImage: "dice") }
                Button { store.addPage() } label: { Label("Add Page", systemImage: "plus.rectangle.portrait") }
                Divider()
                Button(role: .destructive) { store.clearPages() } label: { Label("Clear All Pages", systemImage: "trash") }
            } label: {
                Label("Layout", systemImage: "dice")
            }
            .help("Shuffle the paper, add a page, or clear every page to start from scratch")
            Button { store.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show where every story stands (⌥⌘I)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.exportPDF() } label: {
                Label("Export PDF", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .prominent()
            .help("Save the paper as a print-ready PDF (⇧⌘E)")
        }
    }
}

extension View {
    /// The window's main action for the current step.
    @ViewBuilder func prominent() -> some View {
        buttonStyle(RainbowProminentStyle())
    }
}

/// Step one: the stories, by desk, and the editor.
struct StoriesView: View {
    @Environment(IssueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let i = store.selectedIndex {
                ArticleEditor(article: $store.issue.articles[i])
                    .id(store.issue.articles[i].id)
            } else if let e = store.selectedExtraIndex {
                ExtraEditor(extra: $store.issue.extras[e])
                    .id(store.issue.extras[e].id)
            } else {
                EmptyEditorView()
            }
        }
        .searchable(text: $store.search, placement: .sidebar, prompt: "Search stories")
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(IssueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let status: [Article.ID: IssueStore.StoryStatus] = store.issue.paperNotGenerated ? [:] : store.storyStatus()
        List(selection: $store.selection) {
            ForEach(Desk.allCases) { desk in
                let items = store.articles(on: desk)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { a in
                            ArticleRow(article: a, pages: store.issue.paperNotGenerated ? nil : (status[a.id]?.pages ?? []))
                                .tag(a.id)
                                .contextMenu {
                                    Menu("Move to") {
                                        ForEach(Desk.allCases) { d in
                                            Button(d.rawValue) { move(a.id, to: d) }
                                        }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.delete(a.id) }
                                }
                        }
                    } header: {
                        Label(desk.rawValue, systemImage: desk.symbol)
                    }
                }
            }
            if !store.issue.extras.isEmpty {
                Section {
                    ForEach(store.issue.extras) { e in
                        ExtraRow(extra: e)
                            .tag(e.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.removeExtra(e.id) }
                            }
                    }
                } header: {
                    Label("Ads & Graphics", systemImage: "rectangle.on.rectangle.angled")
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let id = store.selection { store.delete(id) } }
        .dropDestination(for: URL.self) { urls, _ in
            // image or PDF files dropped on the sidebar come in as images
            let files = urls.filter { ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "pdf"].contains($0.pathExtension.lowercased()) }
            for u in files { store.addExtra(u.pathExtension.lowercased() == "pdf" ? .ad : .image, file: u) }
            return !files.isEmpty
        }
                .safeAreaInset(edge: .top, spacing: 0) { IssueMasthead() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(store.issue.articles.count) stories")
                Spacer()
                Text("\(store.totalWords.formatted()) words")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func move(_ id: Article.ID, to desk: Desk) {
        guard let i = store.issue.articles.firstIndex(where: { $0.id == id }) else { return }
        store.issue.articles[i].desk = desk
        store.scheduleSave()
    }
}

struct IssueMasthead: View {
    @Environment(IssueStore.self) private var store
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Wordmark(size: 28)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .popover(isPresented: $editing, arrowEdge: .bottom) { IssueDetailsForm().padding(16).frame(width: 300) }
        .help("Issue details")
    }

    private var subtitle: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return "\(f.string(from: store.issue.date)) · Vol. \(store.issue.volume) Ed. \(store.issue.edition)"
    }
}

struct IssueDetailsForm: View {
    @Environment(IssueStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            TextField("Volume", text: $store.issue.volume)
            TextField("Edition", text: $store.issue.edition)
            DatePicker("Date", selection: $store.issue.date, displayedComponents: .date)
        }
        .onChange(of: store.issue.date) { store.scheduleSave() }
        .onChange(of: store.issue.volume) { store.scheduleSave() }
        .onChange(of: store.issue.edition) { store.scheduleSave() }
    }
}

struct ArticleRow: View {
    let article: Article
    var pages: [Int]? = nil          // where it runs, once the paper exists

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(article.plainHeadline.isEmpty ? "Untitled story" : article.plainHeadline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(article.plainHeadline.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)       // the whole headline, however many lines
                Spacer(minLength: 0)
                if let pages, article.body.contains(where: { !$0.trimmed.isEmpty }) {
                    Text(pages.isEmpty ? "on hold" : pages.count == 1 ? "p. \(pages[0])" : "p. \(pages.first!)–\(pages.last!)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(pages.isEmpty ? Color.orange : Color.secondary)
                        .background(Capsule().fill(pages.isEmpty ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12)))
                        .fixedSize()
                }
            }
            HStack(spacing: 5) {
                Text(article.author.isEmpty ? "No byline" : Markup.plain(article.author))
                Text("·")
                Text("\(article.wordCount) words")
                if !article.photos.isEmpty {
                    Image(systemName: article.photos.count > 1 ? "photo.stack" : "photo").imageScale(.small)
                    if article.photos.count > 1 { Text("\(article.photos.count)") }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyEditorView: View {
    @Environment(IssueStore.self) private var store
    var body: some View {
        ContentUnavailableView {
            Label("No Story Selected", systemImage: "newspaper")
        } description: {
            Text("Paste a whole story with ⇧⌘V — the headline, byline and body are picked out for you.")
        } actions: {
            Button("Paste Article") { store.pasteArticle() }
                .buttonStyle(RainbowProminentStyle())
            Button("New Article") { store.newArticle() }
        }
    }
}
