import SwiftUI
import AppKit

/// The story body: a native text view set in Minion with the paper's indents (none on the first paragraph). Pasting keeps only italics/bold,
/// cleans quotes and dashes, and the content is stored as paragraphs with *italic* / **bold** markup.
struct BodyEditor: NSViewRepresentable {
    @Binding var paragraphs: [String]
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TypesetTextView {
        let tv = TypesetTextView(frame: .zero)
        tv.placeholder = placeholder
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.usesFindBar = true
        tv.typingAttributes = Markup.baseAttributes()
        tv.textStorage?.setAttributedString(Markup.attributed(paragraphs))
        tv.textStorage.map { Theme.indentParagraphs($0) }
        tv.delegate = context.coordinator
        context.coordinator.last = paragraphs
        return tv
    }

    func updateNSView(_ tv: TypesetTextView, context: Context) {
        context.coordinator.parent = self
        guard paragraphs != context.coordinator.last else { return }
        tv.textStorage?.setAttributedString(Markup.attributed(paragraphs))
        tv.textStorage.map { Theme.indentParagraphs($0) }
        context.coordinator.last = paragraphs
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: TypesetTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height) + 8
        return CGSize(width: width, height: max(h, 160))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BodyEditor
        var last: [String] = []
        init(_ parent: BodyEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? TypesetTextView, let storage = tv.textStorage else { return }
            Theme.indentParagraphs(storage)                         // the first paragraph flush, the rest indented
            let paras = Markup.paragraphs(from: storage)
            last = paras
            parent.paragraphs = paras
            tv.invalidateIntrinsicContentSize()
            tv.needsDisplay = true
        }
    }
}

final class TypesetTextView: NSTextView {
    var placeholder = ""

    /// Paste keeps only italics/bold and the text itself; everything is re-set in the house style.
    override func paste(_ sender: Any?) {
        let paras = SmartPaste.paragraphs(from: .general)
        guard !paras.isEmpty else { super.paste(sender); return }
        insertText(Markup.attributed(paras), replacementRange: selectedRange())
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(size: Theme.bodySize, italic: true),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: Theme.bodyParagraphStyle(size: Theme.bodySize, first: true)
        ]
        NSAttributedString(string: placeholder, attributes: attrs).draw(in: bounds.insetBy(dx: textContainerInset.width, dy: textContainerInset.height))
    }
}
