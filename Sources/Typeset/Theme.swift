import SwiftUI
import AppKit
import CoreText

/// The paper's house style, as it appears on screen.
enum Theme {
    // Colours exactly as InDesign exported them in the PDF.
    static let nameplateRed = Color(red: 0.8226, green: 0.1362, blue: 0.1634)
    static let bylineRed = Color(red: 0.8528, green: 0.2622, blue: 0.1580)
    static let rule = Color.primary.opacity(0.14)

    // The app's own colours (not the paper's): the rainbow from the app icon, left to right
    // (`tools/make_resources.py icon`). Red in the app's chrome means a status or a problem, nothing else.
    static let rainbowColors: [Color] = EmptyFrameArt.rainbow.map { Color(nsColor: $0) }
    static let rainbow = LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
    /// One colour standing for the rainbow, for the few system controls that take only a solid tint
    /// (the sidebar's selected row, focus rings): the rainbow's blue.
    static let brandSolid = rainbowColors[4]

    /// The app's name as its icon sets it: SF Pro at weight 900, the letters a left-to-right rainbow.
    static func wordmark(_ size: CGFloat) -> Font { .system(size: size, weight: .black) }

    static let bodySize: CGFloat = 15.5

    static func font(_ postScript: String, size: CGFloat, fallback: Font) -> Font {
        FontCheck.resolve(postScript).map { .custom($0, size: size) } ?? fallback
    }

    static func headline(_ size: CGFloat) -> Font { font("UtopiaStd-SemiboldSubh", size: size, fallback: .system(size: size, weight: .semibold, design: .serif)) }
    static func deck(_ size: CGFloat) -> Font { font("MinionPro-It", size: size, fallback: .system(size: size, design: .serif).italic()) }
    static func byline(_ size: CGFloat) -> Font { font("Raleway-SemiBold", size: size, fallback: .system(size: size, weight: .semibold)) }
    static func bylineTitle(_ size: CGFloat) -> Font { font("MyriadPro-It", size: size, fallback: .system(size: size).italic()) }
    static func caption(_ size: CGFloat) -> Font { font("MinionPro-Bold", size: size, fallback: .system(size: size, weight: .bold, design: .serif)) }
    static func pullQuote(_ size: CGFloat) -> Font { font("Raleway", size: size, fallback: .system(size: size, weight: .light)) }
    static func nameplate(_ size: CGFloat) -> Font { font("Raleway", size: size, fallback: .system(size: size, weight: .light)) }

    static func bodyFont(size: CGFloat, italic: Bool = false, bold: Bool = false) -> NSFont {
        let name = bold ? (italic ? "MinionPro-BoldIt" : "MinionPro-Bold") : (italic ? "MinionPro-It" : "MinionPro-Regular")
        if let f = NSFont(name: name, size: size) { return f }
        var f = NSFont.systemFont(ofSize: size)
        if let serif = f.fontDescriptor.withDesign(.serif) { f = NSFont(descriptor: serif, size: size) ?? f }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if italic { traits.insert(.italic) }
        if bold { traits.insert(.bold) }
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: size) ?? f
    }

    /// Body paragraphs as the paper sets them: a first-line indent, except the story's first paragraph (`first`),
    /// which is flush left.
    static func bodyParagraphStyle(size: CGFloat, first: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = first ? 0 : size * 1.5
        p.lineHeightMultiple = 1.32
        p.paragraphSpacing = size * 0.25
        return p
    }

    /// Sets the editor's text as the paper does: every paragraph indented but the first.
    static func indentParagraphs(_ s: NSMutableAttributedString, size: CGFloat = bodySize) {
        guard s.length > 0 else { return }
        let ns = s.string as NSString
        let first = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        s.beginEditing()
        s.addAttribute(.paragraphStyle, value: bodyParagraphStyle(size: size, first: true), range: first)
        if NSMaxRange(first) < s.length {
            s.addAttribute(.paragraphStyle, value: bodyParagraphStyle(size: size),
                           range: NSRange(location: NSMaxRange(first), length: s.length - NSMaxRange(first)))
        }
        s.endEditing()
    }

    /// Byline titles used in the paper, derived from a staff-box role.
    static func bylineTitle(for role: String) -> String {
        let r = role.lowercased()
        if r.contains("editor in chief") { return "Editor in Chief" }
        if r.contains("managing editor") { return role }
        if r.contains("editor") || r.contains("director") || r.contains("manager") { return role }
        return "Staff Reporter"
    }

    /// Rough length in the paper's columns: about 49 characters a line, 78 lines to a full column.
    static func estimate(_ paragraphs: [String]) -> (lines: Int, columns: Double) {
        let lines = paragraphs.reduce(0) { n, p in
            let chars = Markup.plain(p).count
            return n + (chars == 0 ? 0 : Int((Double(chars) + 6) / 49) + 1)
        }
        return (lines, Double(lines) / 78)
    }
}

enum FontLoader {
    /// Register the paper's fonts, for this process: any a build carries (Contents/Resources/Fonts) and the ones
    /// added in setup (Application Support/Typeset/Fonts). Fonts installed on the Mac need nothing.
    static func registerBundledFonts() {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), FontCheck.userFontsDir].compactMap { $0 }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where FontCheck.fontExtensions.contains(url.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
