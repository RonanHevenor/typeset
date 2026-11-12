import SwiftUI
import AppKit

/// A one-paragraph field that takes *italic* (⌘I, or Format › Italic), stored as markup like the body and the
/// headline: the kicker, the teaser, the byline, captions, credits, the pull quote. Return moves on.
struct MarkupField: NSViewRepresentable {
    @Binding var markup: String
    var placeholder: String
    /// The face the field shows its text in; italic runs take `HouseStyle.italic` of it.
    var font: NSFont
    var color: NSColor = .textColor
    var alignment: NSTextAlignment = .natural

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkupTextView {
        let tv = MarkupTextView(frame: .zero)
        tv.field = self
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
        tv.typingAttributes = attributes(italic: false)
        tv.textStorage?.setAttributedString(attributed(markup))
        tv.delegate = context.coordinator
        context.coordinator.last = markup
        return tv
    }

    func updateNSView(_ tv: MarkupTextView, context: Context) {
        context.coordinator.parent = self
        tv.field = self
        guard markup != context.coordinator.last else { return }
        tv.textStorage?.setAttributedString(attributed(markup))
        context.coordinator.last = markup
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: MarkupTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: width, height: max(ceil(lm.usedRect(for: tc).height), ceil(font.ascender - font.descender + font.leading)) + 2)
    }

    func attributes(italic: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        return [.font: italic ? HouseStyle.italic(font) : font, .foregroundColor: color, .paragraphStyle: p,
                Markup.italicKey: italic, Markup.boldKey: false]
    }

    /// The stored markup as the field shows it.
    func attributed(_ markup: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, italic) in Markup.runs(markup) {
            out.append(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "), attributes: attributes(italic: italic)))
        }
        return out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkupField
        var last = ""
        init(_ parent: MarkupField) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? MarkupTextView, let storage = tv.textStorage else { return }
            let m = Markup.paragraphs(from: storage).joined(separator: " ").replacingOccurrences(of: "**", with: "")
            last = m
            parent.markup = m
            tv.invalidateIntrinsicContentSize()
            tv.needsDisplay = true
        }
    }
}

final class MarkupTextView: NSTextView {
    var field: MarkupField?

    override func insertNewline(_ sender: Any?) { window?.selectNextKeyView(nil) }          // one paragraph: Return moves on
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(nil) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(nil) }

    /// Pasted text comes in as one line of plain words in the field's face.
    override func paste(_ sender: Any?) {
        let paras = SmartPaste.paragraphs(from: .general)
        guard !paras.isEmpty, let field else { super.paste(sender); return }
        let line = paras.map(Markup.plain).joined(separator: " ")
        insertText(NSAttributedString(string: line, attributes: field.attributes(italic: false)), replacementRange: selectedRange())
    }

    /// Format › Italic (⌘I) toggles italics over the selection; bold isn't a field's to have and is ignored.
    override func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager, let storage = textStorage, let field else { return }
        let range = selectedRange()
        let current: [NSAttributedString.Key: Any] = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        let italicNow = current[Markup.italicKey] as? Bool ?? false
        let probe = fm.convert(Theme.bodyFont(size: 12, italic: italicNow, bold: false))
        let wantsItalic = probe.fontDescriptor.symbolicTraits.contains(.italic) || probe.fontName.lowercased().hasSuffix("-it")
        let wantsBold = probe.fontDescriptor.symbolicTraits.contains(.bold) || probe.fontName.lowercased().contains("bold")
        if wantsBold { NSSound.beep(); return }
        guard wantsItalic != italicNow else { return }
        let attrs = field.attributes(italic: wantsItalic)
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            storage.addAttributes(attrs, range: range)
            didChangeText()
        }
        typingAttributes = attrs
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, let field, !field.placeholder.isEmpty else { return }
        var attrs = field.attributes(italic: false)
        attrs[.foregroundColor] = NSColor.placeholderTextColor
        NSAttributedString(string: field.placeholder, attributes: attrs).draw(in: bounds)
    }
}
