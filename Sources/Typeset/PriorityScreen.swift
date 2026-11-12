import SwiftUI

/// Step two: drag the stories into order of importance. The order decides the front page and the run of the paper.
struct PriorityScreen: View {
    @Environment(IssueStore.self) private var store
    @State private var selection: Set<Article.ID> = []

    var body: some View {
        let placements = store.placements
        List(selection: $selection) {
            ForEach(Array(store.issue.articles.enumerated()), id: \.element.id) { i, a in
                PriorityRow(rank: i + 1, article: a, placement: placements[a.id] ?? .inside)
                    .tag(a.id)
                    .contextMenu {
                        Button("Move to Top") { move(a.id, to: 0) }
                        Button("Move Up") { move(a.id, by: -1) }.disabled(i == 0)
                        Button("Move Down") { move(a.id, by: 1) }.disabled(i == store.issue.articles.count - 1)
                        Button("Move to Bottom") { move(a.id, to: store.issue.articles.count - 1) }
                    }
            }
            .onMove { from, to in
                withAnimation(.snappy) { store.issue.articles.move(fromOffsets: from, toOffset: to) }
                store.scheduleSave()
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Order of Importance")
                .font(.system(size: 26, weight: .bold))
            Text("Drag stories into priority order. The top two lead the front page, and the rest fill the inside pages in this order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            let count = store.placements.values.filter { $0 != .skipped }.count
            Text("\(count) stories · \(store.totalWords.formatted()) words")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Back to Stories") { store.go(to: .stories) }
            Button { store.advance() } label: {
                Label("Generate Paper", systemImage: "newspaper")
            }
            .prominent()
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func move(_ id: Article.ID, by delta: Int) {
        guard let i = store.issue.articles.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: i + delta)
    }

    private func move(_ id: Article.ID, to target: Int) {
        guard let i = store.issue.articles.firstIndex(where: { $0.id == id }) else { return }
        let t = target.clamped(0, store.issue.articles.count - 1)
        withAnimation(.snappy) {
            let a = store.issue.articles.remove(at: i)
            store.issue.articles.insert(a, at: t)
        }
        store.scheduleSave()
    }
}

struct PriorityRow: View {
    @Environment(IssueStore.self) private var store
    let rank: Int
    let article: Article
    let placement: IssueStore.Placement

    var body: some View {
        HStack(spacing: 16) {
            Text("\(rank)")
                .font(Theme.headline(28))
                .monospacedDigit()
                .foregroundStyle(placement == .frontLead || placement == .front ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(.secondary))
                .frame(width: 42, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.plainHeadline.isEmpty ? "Untitled story" : article.plainHeadline)
                    .font(Theme.headline(18))
                    .foregroundStyle(placement == .skipped ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: article.desk.symbol)
                    Text(article.desk.rawValue)
                    Text("·")
                    Text(article.author.isEmpty ? "No byline" : Markup.plain(article.author))
                    Text("·")
                    Text("\(article.wordCount) words")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            PlacementBadge(placement: placement)
            thumbnail
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            if let p = article.photos.first, let img = store.composer.image(p.path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.5))
            }
        }
        .frame(width: 66, height: 46)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if article.photos.count > 1 {
                Text("\(article.photos.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
    }
}

struct PlacementBadge: View {
    let placement: IssueStore.Placement

    var body: some View {
        let (title, filled): (String, Bool) = {
            switch placement {
            case .frontLead: ("Front · Lead", true)
            case .front: ("Front Page", true)
            case .inside: ("Inside", false)
            case .skipped: ("No Text — Skipped", false)
            }
        }()
        let front = placement == .frontLead || placement == .front
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(front ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(Color.secondary))
            .background {
                // the front page's stories: the app icon's look, a black tile with rainbow letters
                if filled { Capsule().fill(Color.black.opacity(placement == .frontLead ? 0.92 : 0.78)) }
                else { Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1) }
            }
            .fixedSize()
    }
}
