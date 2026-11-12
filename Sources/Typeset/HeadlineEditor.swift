import SwiftUI
import AppKit

/// The headline field: one paragraph in the headline face, with the body editor's controls. ⌘I sets a title
/// inside it in italics (the paper's bold italic Utopia); the result is stored as *markup* like the body.
struct HeadlineEditor: NSViewRepresentable {
    @Binding var markup: String
    var placeholder: String
    static let size: CGFloat = 34

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HeadlineTextView {
        let tv = HeadlineTextView(frame: .zero)
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
        tv.typingAttributes = Self.attributes(italic: false)
        tv.textStorage?.setAttributedString(Self.attributed(markup))
        tv.delegate = context.coordinator
        context.coordinator.last = markup
        return tv
    }

    func updateNSView(_ tv: HeadlineTextView, context: Context) {
        context.coordinator.parent = self
        guard markup != context.coordinator.last else { return }
        tv.textStorage?.setAttributedString(Self.attributed(markup))
        context.coordinator.last = markup
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: HeadlineTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: width, height: max(ceil(lm.usedRect(for: tc).height) + 4, Self.size * 1.2))
    }

    static func attributes(italic: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 0
        p.minimumLineHeight = size * 1.08
        p.maximumLineHeight = size * 1.08
        let face = italic ? HouseStyle.headlineItalicFace : HouseStyle.headlineFace
        var font = NSFont(name: face, size: size)
        if font == nil {
            var f = NSFont.systemFont(ofSize: size, weight: .semibold)
            if let d = f.fontDescriptor.withDesign(.serif) { f = NSFont(descriptor: d, size: size) ?? f }
            font = italic ? NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? f : f
        }
        return [.font: font!, .foregroundColor: NSColor.textColor, .paragraphStyle: p, Markup.italicKey: italic, Markup.boldKey: false]
    }

    /// The stored markup as the editor shows it: italic runs in the italic headline face.
    static func attributed(_ markup: String) -> NSAttributedString {
        let marked = Markup.attributed([markup], size: 12)
        let out = NSMutableAttributedString(string: marked.string.replacingOccurrences(of: "\n", with: " "), attributes: attributes(italic: false))
        marked.enumerateAttribute(.font, in: NSRange(location: 0, length: marked.length)) { value, range, _ in
            let name = ((value as? NSFont)?.fontName ?? "").lowercased()
            if name.hasSuffix("-it") || name.contains("boldit") { out.addAttributes(attributes(italic: true), range: range) }
        }
        return out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HeadlineEditor
        var last = ""
        init(_ parent: HeadlineEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? HeadlineTextView, let storage = tv.textStorage else { return }
            let m = Markup.paragraphs(from: storage).joined(separator: " ").replacingOccurrences(of: "**", with: "")
            last = m
            parent.markup = m
            tv.invalidateIntrinsicContentSize()
            tv.needsDisplay = true
        }
    }
}

final class HeadlineTextView: NSTextView {
    var placeholder = ""

    override func insertNewline(_ sender: Any?) { window?.selectNextKeyView(nil) }          // one paragraph: Return moves on

    /// Pasted text comes in as one line of plain words in the headline face.
    override func paste(_ sender: Any?) {
        let paras = SmartPaste.paragraphs(from: .general)
        guard !paras.isEmpty else { super.paste(sender); return }
        let line = paras.map(Markup.plain).joined(separator: " ")
        insertText(NSAttributedString(string: line, attributes: HeadlineEditor.attributes(italic: false)), replacementRange: selectedRange())
    }

    /// Format › Italic (⌘I) toggles the italic headline face over the selection; bold has no face here and is ignored.
    override func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager, let storage = textStorage else { return }
        let range = selectedRange()
        let current: [NSAttributedString.Key: Any] = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        let italicNow = current[Markup.italicKey] as? Bool ?? false
        // what the Font menu asked for, read off a face that has every variant
        let probe = fm.convert(Theme.bodyFont(size: 12, italic: italicNow, bold: false))
        let wantsItalic = probe.fontDescriptor.symbolicTraits.contains(.italic) || probe.fontName.lowercased().hasSuffix("-it")
        let wantsBold = probe.fontDescriptor.symbolicTraits.contains(.bold) || probe.fontName.lowercased().contains("bold")
        if wantsBold { NSSound.beep(); return }
        guard wantsItalic != italicNow else { return }
        let attrs = HeadlineEditor.attributes(italic: wantsItalic)
        if range.length > 0 {
            if shouldChangeText(in: range, replacementString: nil) {
                storage.addAttributes(attrs, range: range)
                didChangeText()
            }
        }
        typingAttributes = attrs
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        var attrs = HeadlineEditor.attributes(italic: false)
        attrs[.foregroundColor] = NSColor.placeholderTextColor
        NSAttributedString(string: placeholder, attributes: attrs).draw(in: bounds)
    }
}
