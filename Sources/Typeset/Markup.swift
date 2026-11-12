import AppKit

/// Converts between the editor's attributed text and the stored paragraph markup (*italic*, **bold**).
/// A literal asterisk or backslash in the copy is stored escaped (\* and \\), so "N*SYNC" stays text.
enum Markup {
    /// Text as stored: literal asterisks and backslashes escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
    }

    /// Stored markup as plain text: markers dropped, escapes undone.
    static func plain(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "*" { continue }
            out.append(ch)
        }
        return out
    }

    /// A field's markup as runs of text, each italic or not (*italic*; a field has no bold, so ** is dropped).
    static func runs(_ s: String) -> [(text: String, italic: Bool)] {
        var out: [(text: String, italic: Bool)] = [], buf = "", italic = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { buf.append(chars[i + 1]); i += 2; continue }
            if chars[i] == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { i += 2; continue }
                if !buf.isEmpty { out.append((buf, italic)); buf = "" }
                italic.toggle(); i += 1; continue
            }
            buf.append(chars[i]); i += 1
        }
        if !buf.isEmpty { out.append((buf, italic)) }
        return out
    }

    /// Lines cut from one run of markup, each made whole: italics open at a line's end close there and open
    /// again at the start of the next.
    static func balanced(_ lines: [String]) -> [String] {
        var open = false
        return lines.map { l in
            var s = open ? "*" + l : l
            let chars = Array(l)
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "*" {
                    if i + 1 < chars.count, chars[i + 1] == "*" { i += 2; continue }
                    open.toggle()
                }
                i += 1
            }
            if open { s += "*" }
            return s
        }
    }

    private static let italicOpen = "\u{E000}", italicClose = "\u{E001}"
    private static let boldOpen = "\u{E002}", boldClose = "\u{E003}"

    // MARK: attributed text -> paragraphs

    /// Set on a run by an editor whose faces don't say (the headline's): what the markup should record.
    static let italicKey = NSAttributedString.Key("typeset.italic")
    static let boldKey = NSAttributedString.Key("typeset.bold")

    static func paragraphs(from att: NSAttributedString) -> [String] {
        var out: [String] = []
        var current = ""
        let ns = att.string as NSString
        att.enumerateAttributes(in: NSRange(location: 0, length: att.length)) { attrs, range, _ in
            let text = ns.substring(with: range)
            var (italic, bold) = traits(of: attrs[.font] as? NSFont)
            if let i = attrs[italicKey] as? Bool { italic = i }
            if let b = attrs[boldKey] as? Bool { bold = b }
            let pieces = text.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{2029}"))
            for (i, piece) in pieces.enumerated() {
                if i > 0 { out.append(current); current = "" }
                current += wrap(escape(piece), italic: italic, bold: bold)
            }
        }
        out.append(current)
        return out.map(finish)
    }

    private static func traits(of font: NSFont?) -> (Bool, Bool) {
        guard let font else { return (false, false) }
        let t = font.fontDescriptor.symbolicTraits
        let name = font.fontName.lowercased()
        let italic = t.contains(.italic) || name.contains("italic") || name.hasSuffix("-it") || name.contains("oblique")
        let bold = t.contains(.bold) || name.contains("bold") || name.contains("semibold") || name.contains("black")
        return (italic, bold)
    }

    /// Wrap the non-blank core of a run in placeholder markers, keeping surrounding spaces outside.
    private static func wrap(_ s: String, italic: Bool, bold: Bool) -> String {
        guard italic || bold, s.contains(where: { !$0.isWhitespace }) else { return s }
        let lead = s.prefix(while: { $0.isWhitespace })
        let trail = String(s.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let core = s.dropFirst(lead.count).dropLast(trail.count)
        var w = String(core)
        // bold inside, italic outside, always: where two runs meet, the italic close and open sit next to each
        // other and merge, so a run of asterisks never holds two italic markers (which would read back as bold)
        if bold { w = boldOpen + w + boldClose }
        if italic { w = italicOpen + w + italicClose }
        return lead + w + trail
    }

    /// Merge adjacent runs of the same style, then turn markers into * and **.
    private static func finish(_ s: String) -> String {
        var t = s
        var changed = true
        while changed {
            changed = false
            for (close, open) in [(italicClose, italicOpen), (boldClose, boldOpen)] {
                while let r = t.range(of: close + "(\\s*)" + open, options: .regularExpression) {
                    let inner = String(t[r]).replacingOccurrences(of: close, with: "").replacingOccurrences(of: open, with: "")
                    t.replaceSubrange(r, with: inner)
                    changed = true
                }
            }
        }
        return t.replacingOccurrences(of: boldOpen, with: "**").replacingOccurrences(of: boldClose, with: "**")
            .replacingOccurrences(of: italicOpen, with: "*").replacingOccurrences(of: italicClose, with: "*")
    }

    // MARK: paragraphs -> attributed text

    static func attributed(_ paragraphs: [String], size: CGFloat = Theme.bodySize) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes(size: size))) }
            out.append(styled(p, size: size))
        }
        return out
    }

    static func baseAttributes(size: CGFloat = Theme.bodySize, italic: Bool = false, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: Theme.bodyFont(size: size, italic: italic, bold: bold),
         .foregroundColor: NSColor.textColor,
         .paragraphStyle: Theme.bodyParagraphStyle(size: size)]
    }

    private static func styled(_ p: String, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var italic = false, bold = false
        var buffer = ""
        var chars = Array(p)
        func flush() {
            if !buffer.isEmpty { out.append(NSAttributedString(string: buffer, attributes: baseAttributes(size: size, italic: italic, bold: bold))) }
            buffer = ""
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { buffer.append(chars[i + 1]); i += 2; continue }     // an escaped character
            if chars[i] == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { flush(); bold.toggle(); i += 2; continue }
                flush(); italic.toggle(); i += 1; continue
            }
            buffer.append(chars[i]); i += 1
        }
        flush()
        chars.removeAll()
        return out
    }
}
