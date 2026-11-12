import SwiftUI

// The app's own look, apart from the paper it lays out: the rainbow from the app icon (`Theme.rainbow`).
// Red in the app's chrome is kept for status and problems only (overset, blank lines, holes, "too close",
// error badges, the fit gauge's "tight").

/// "Typeset" in SF Pro at weight 900, the letters the app icon's left-to-right rainbow.
struct Wordmark: View {
    var size: CGFloat = 28
    var body: some View {
        Text("Typeset")
            .font(Theme.wordmark(size))
            .tracking(-0.02 * size)
            .foregroundStyle(Theme.rainbow)
            .fixedSize()
            .accessibilityLabel("Typeset")
    }
}

/// The window's main action, in the manner of the app icon: a black tile, the label a rainbow.
struct RainbowProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(Color.white.opacity(0.45)))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.75 : 0.92)))
            .overlay(Capsule().strokeBorder(Theme.rainbow.opacity(enabled ? 0.55 : 0.2), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The Content · Priority · Pages switcher: the current step a black tile with its name in the rainbow.
struct StepSwitcher: View {
    let selection: Stage
    let go: (Stage) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Stage.allCases) { stage in
                let on = stage == selection
                Button { go(stage) } label: {
                    Text(stage.title)
                        .font(.body.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background { if on { Capsule().fill(Color.black.opacity(0.92)) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// A small label chip (a story's desk, an extra's kind) in the rainbow: rainbow text on a faint rainbow wash.
struct RainbowChip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .foregroundStyle(Theme.rainbow)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.rainbow.opacity(0.12)))
    }
}
