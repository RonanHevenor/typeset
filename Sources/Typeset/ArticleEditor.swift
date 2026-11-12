import SwiftUI
import UniformTypeIdentifiers

struct ArticleEditor: View {
    @Binding var article: Article
    @Environment(IssueStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DeskChip(desk: $article.desk)

                MarkupField(markup: $article.kicker, placeholder: "KICKER — A LABEL OVER THE HEADLINE, E.G. WOMEN’S HOCKEY (OPTIONAL)",
                            font: .systemFont(ofSize: 11, weight: .bold), color: .secondaryLabelColor)
                    .padding(.top, 18)

                HeadlineEditor(markup: $article.headline, placeholder: "Headline")
                    .padding(.top, 6)

                MarkupField(markup: $article.teaser, placeholder: "Front-page teaser — a shorter headline for the top of page 1 (optional)",
                            font: HouseStyle.font("MinionPro-It", 14), color: .secondaryLabelColor)
                    .padding(.top, 8)

                HStack(spacing: 4) {
                    Text("Jump line: See").foregroundStyle(.secondary)
                    TextField(HouseStyle.jumpWord(article.headline), text: $article.jump)
                        .textFieldStyle(.plain)
                        .fixedSize()
                    Text(", Page N.").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, 8)
                .help("The word the jump line uses when the story continues on another page; empty uses the headline's")

                BylineField(author: $article.author, title: $article.authorTitle)
                    .padding(.top, 26)

                Rule().padding(.top, 22).padding(.bottom, 26)

                BodyEditor(paragraphs: $article.body, placeholder: "Write or paste the story…")

                Rule().padding(.top, 34).padding(.bottom, 30)

                PhotosSection(photos: $article.photos)

                PullQuoteField(text: $article.pullQuote)
                    .padding(.top, 34)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 40)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) { StatsBar(article: article) }
        .onChange(of: article) { was, now in store.reflowArt(for: was, now: now); store.scheduleSave() }
    }
}

// MARK: - Pieces

struct PaperBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(white: 0.11) : Color(red: 0.992, green: 0.988, blue: 0.980))
            .ignoresSafeArea()
    }
}

struct Rule: View {
    var body: some View {
        Rectangle().fill(Theme.rule).frame(height: 1)
    }
}

struct DeskChip: View {
    @Binding var desk: Desk
    var body: some View {
        Menu {
            Picker("Desk", selection: $desk) {
                ForEach(Desk.allCases) { d in Label(d.rawValue, systemImage: d.symbol).tag(d) }
            }
            .pickerStyle(.inline)
        } label: {
            RainbowChip {
                HStack(spacing: 5) {
                    Text(desk.rawValue.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct BylineField: View {
    @Binding var author: String
    @Binding var title: String
    @Environment(IssueStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                MarkupField(markup: $author, placeholder: "Author", font: HouseStyle.font("Raleway-SemiBold", 16), color: HouseStyle.bylineRed)
                MarkupField(markup: $title, placeholder: "Title — e.g. Senior Reporter", font: HouseStyle.font("MyriadPro-It", 14), color: .secondaryLabelColor)
            }

            Spacer(minLength: 0)

            Menu {
                    ForEach(store.staff.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { m in
                        Button(m.role.isEmpty ? m.name : "\(m.name) — \(m.role)") {
                            author = m.name
                            title = Theme.bylineTitle(for: m.role)
                        }
                    }
                    if !store.staff.isEmpty { Divider() }
                    Button(store.staff.isEmpty ? "Set Up Staff…" : "Edit Staff…") { openWindow(id: "setup") }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(store.staff.isEmpty ? "Add your staff in setup to pick bylines from a list" : "Pick from the staff box")
        }
    }
}

struct PhotosSection: View {
    @Binding var photos: [Photo]
    @Environment(IssueStore.self) private var store
    @State private var targeted = false
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 20, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(photos.isEmpty ? "Art" : "Art · \(photos.count)")
                Spacer()
                if !photos.isEmpty {
                    Button(action: choose) { Label("Add Photos", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            if photos.isEmpty {
                addTile(height: 170, big: true)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach($photos) { $photo in
                        PhotoCard(photo: $photo,
                                  isLead: photo.id == photos.first?.id,
                                  onRemove: { remove(photo.id) },
                                  onMakeLead: { move(photo.id, to: 0) },
                                  onMove: { delta in shift(photo.id, by: delta) })
                    }
                    addTile(height: 196, big: false)
                }
            }
        }
    }

    private func addTile(height: CGFloat, big: Bool) -> some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                Image(systemName: big ? "photo.on.rectangle.angled" : "plus")
                    .font(.system(size: big ? 30 : 22, weight: .light))
                Text(big ? "Drop photos or illustrations" : "Add photos")
                    .font(.system(size: 13, weight: .medium))
                if big {
                    Text("or click to choose — several at once is fine")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(targeted ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(targeted ? AnyShapeStyle(Theme.rainbow.opacity(0.08)) : AnyShapeStyle(Color.primary.opacity(0.025)))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .foregroundStyle(targeted ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(Color.primary.opacity(0.18)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { attach(url) }
                }
            }
            return !providers.isEmpty
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { panel.urls.forEach(attach) }
    }

    private func attach(_ url: URL) {
        if let stored = store.importImage(url) {
            withAnimation(.snappy) { photos.append(Photo(path: stored)) }
        }
    }

    private func remove(_ id: Photo.ID) {
        withAnimation(.snappy) { photos.removeAll { $0.id == id } }
    }

    private func move(_ id: Photo.ID, to index: Int) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { let p = photos.remove(at: i); photos.insert(p, at: max(0, min(index, photos.count))) }
    }

    private func shift(_ id: Photo.ID, by delta: Int) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: i + delta)
    }
}

struct PhotoCard: View {
    @Binding var photo: Photo
    var isLead: Bool
    var onRemove: () -> Void
    var onMakeLead: () -> Void
    var onMove: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            thumbnail
                .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isLead {
                        Text("LEAD")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(1.1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        HStack(spacing: 6) {
                            if !isLead { roundButton("star", help: "Make lead photo", action: onMakeLead) }
                            roundButton("xmark", help: "Remove photo", action: onRemove)
                        }
                        .padding(10)
                        .transition(.opacity)
                    }
                }
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
                .contextMenu {
                    if !isLead { Button("Make Lead Photo", action: onMakeLead) }
                    Button("Move Earlier") { onMove(-1) }
                    Button("Move Later") { onMove(1) }
                    Divider()
                    Button("Remove Photo", role: .destructive, action: onRemove)
                }
            MarkupField(markup: $photo.caption, placeholder: "Caption", font: HouseStyle.font("MinionPro-Bold", 12.5))
            MarkupField(markup: $photo.credit, placeholder: "Credit — e.g. Sam Rivera/Staff", font: HouseStyle.font("MyriadPro-It", 12.5), color: .secondaryLabelColor)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = IssueStore.imageURL(for: photo.path), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.05)
                Image(systemName: "photo").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            }
        }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .help(help)
    }
}

struct PullQuoteField: View {
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Pull quote")
            VStack(spacing: 14) {
                Rule()
                MarkupField(markup: $text, placeholder: "An optional line to pull out of the story", font: HouseStyle.font("Raleway", 21), alignment: .center)
                    .frame(maxWidth: .infinity)
                Rule()
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
    }
}

struct StatsBar: View {
    let article: Article

    var body: some View {
        let est = Theme.estimate(article.body)
        HStack(spacing: 16) {
            Spacer()
            Label("\(article.wordCount.formatted()) words", systemImage: "text.alignleft")
            Text("≈ \(est.lines) lines")
            Text(String(format: "%.1f columns", est.columns))
            if !article.photos.isEmpty {
                Label("\(article.photos.count)", systemImage: article.photos.count > 1 ? "photo.stack" : "photo")
            }
            Spacer()
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}
