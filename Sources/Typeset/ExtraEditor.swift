import SwiftUI
import AppKit

/// An ad, standalone image or graphic: what it is, how wide it runs, and its caption if it has one.
struct ExtraEditor: View {
    @Environment(IssueStore.self) private var store
    @Binding var extra: Extra

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                kindChip
                TextField("Title", text: $extra.title, prompt: Text(extra.kind == .ad ? "Advertiser" : "Title"))
                    .textFieldStyle(.plain)
                    .font(Theme.headline(32))
                preview
                sizing
                if extra.kind != .ad {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkupField(markup: $extra.caption, placeholder: "Caption", font: HouseStyle.font("MinionPro-Bold", 15))
                        MarkupField(markup: $extra.credit, placeholder: "Credit", font: HouseStyle.font("MyriadPro-It", 14), color: .secondaryLabelColor)
                    }
                }
                HStack {
                    Button("Replace File…") { replaceFile() }
                    Spacer()
                    Button("Delete", role: .destructive) { store.removeExtra(extra.id) }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 40)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
        .background(PaperBackground())
        .onChange(of: extra) { store.scheduleSave() }
    }

    private var kindChip: some View {
        Menu {
            ForEach(Extra.Kind.allCases) { k in
                Button { extra.kind = k } label: { Label(k.rawValue, systemImage: k.symbol) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: extra.kind.symbol)
                Text(extra.kind.rawValue.uppercased())
                    .tracking(1.5)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.rainbow)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.rainbow.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let img = store.composer.image(extra.path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ContentUnavailableView("File Missing", systemImage: "questionmark.square.dashed", description: Text(extra.path))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 420)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }

    private var sizing: some View {
        let g = store.grid
        let w = g.span(extra.columns.clamped(1, g.columns))
        let h = extra.height ?? w / store.composer.aspect(path: extra.path)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Runs at")
                Picker("Width", selection: $extra.columns) {
                    ForEach(1...max(1, g.columns), id: \.self) { Text($0 == 1 ? "1 col" : "\($0) col").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("×")
                    .foregroundStyle(.secondary)
                Stepper(value: Binding(get: { h / 72 }, set: { extra.height = CGFloat($0 * 72) }), in: 0.5...16, step: 0.25) {
                    Text(String(format: "%.2f in tall", h / 72))
                }
                .fixedSize()
                if extra.height != nil {
                    Button("Use file's proportions") { extra.height = nil }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            Text(String(format: "%.1f × %.1f in · %.1f in²", w / 72, h / 72, w * h / 5184))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func replaceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        guard panel.runModal() == .OK, let url = panel.url, let path = store.importImage(url) else { return }
        extra.path = path
    }
}

struct ExtraRow: View {
    @Environment(IssueStore.self) private var store
    let extra: Extra

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = store.composer.image(extra.path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(extra.title.isEmpty ? "Untitled \(extra.kind.rawValue.lowercased())" : extra.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: extra.kind.symbol).imageScale(.small)
                    Text(extra.kind.rawValue)
                    Text("·")
                    Text(extra.columns == 1 ? "1 col" : "\(extra.columns) col")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
