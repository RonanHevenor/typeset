import AppKit
import CoreText

/// The paper's house style for laid-out pages. Change how the paper looks here.
/// Measurements are PostScript points with a top-left origin, taken from the InDesign file.
enum HouseStyle {
    // MARK: page

    static let page = CGSize(width: 801, height: 1242)      // tabloid, 11.125 × 17.25 in
    static let margin: CGFloat = 36
    static let gutter: CGFloat = 12
    static let insideTop: CGFloat = 78                        // first headline, below the folio
    static let bottom: CGFloat = 1206
    static let moduleGap: CGFloat = 20                        // between stories stacked on a page
    static var liveWidth: CGFloat { page.width - 2 * margin }

    // MARK: body type

    static let bodySize: CGFloat = 12
    static let leading: CGFloat = 14.4
    static let indent: CGFloat = 18
    /// Comfortable line length, in characters. Column counts are chosen to land inside it.
    static let lineLength: ClosedRange<Double> = 47...72

    // MARK: colour (as InDesign exported the swatches)

    static let ink = NSColor(srgbRed: 0.1367, green: 0.122, blue: 0.1253, alpha: 1)
    static let red = NSColor(srgbRed: 0.8226, green: 0.1362, blue: 0.1634, alpha: 1)
    static let bylineRed = NSColor(srgbRed: 0.8528, green: 0.2622, blue: 0.1580, alpha: 1)

    // MARK: faces

    static func font(_ name: String, _ size: CGFloat) -> NSFont {
        FontCheck.resolve(name).flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }
    static var bodyFont: NSFont { font("MinionPro-Regular", bodySize) }

    /// The italic of a face, for *italic* in a field: the family's italic, or its roman inside type that is already
    /// italic (a byline title, a teaser, a credit's paper name). Raleway has no italic bundled: it slants instead
    /// (InDesign gets the real italic, see IDMLExport.fontStyle).
    static func italic(_ f: NSFont) -> NSFont {
        let pairs = ["MinionPro-Regular": "MinionPro-It", "MinionPro-It": "MinionPro-Regular", "MinionPro-Medium": "MinionPro-It",
                     "MinionPro-Bold": "MinionPro-BoldIt", "MinionPro-BoldIt": "MinionPro-Bold",
                     "UtopiaStd-SemiboldSubh": "UtopiaStd-BoldIt", "UtopiaStd-BoldIt": "UtopiaStd-SemiboldSubh",
                     "MyriadPro-It": "MyriadPro-Regular", "MyriadPro-Regular": "MyriadPro-It"]
        if let n = pairs[f.fontName], let g = NSFont(name: n, size: f.pointSize) { return g }
        let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
        if let g = NSFont(descriptor: d, size: f.pointSize), g.fontDescriptor.symbolicTraits.contains(.italic), g.familyName == f.familyName { return g }
        return oblique(f)
    }

    /// A face slanted 11°, for one with no italic.
    static func oblique(_ f: NSFont) -> NSFont {
        let m = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
        return NSFont(descriptor: f.fontDescriptor.addingAttributes([.matrix: m]), size: f.pointSize) ?? f
    }

    static func headlineSize(columns: Int) -> CGFloat {
        switch columns { case ...1: 28; case 2: 30; default: 36 }
    }
    static let frontLeadHeadline: CGFloat = 32
    static let frontSecondHeadline: CGFloat = 30
    static let headlineFace = "UtopiaStd-SemiboldSubh"
    static let headlineItalicFace = "UtopiaStd-BoldIt"        // a title inside a headline
    static let headlineGap: CGFloat = 3                       // under the headline's last line box, to the byline rule
    static let bylineHeight: CGFloat = 35                     // rule, name, title, rule (one line of names)
    static let bylineLeading: CGFloat = 14.3                  // each further line of names
    static let kickerFace = "Raleway-Bold"                    // small capitals over the headline, as the Times sets a label
    static let kickerSize: CGFloat = 10
    static let kickerHeight: CGFloat = 18                     // the label and the air below (where its short rule was)
    static let storyRule: CGFloat = 0.5                       // the hairline between stories that touch
    static let photoOutline: CGFloat = 0.75                   // stroked inside the picture's frame
    static let pullQuoteRule: CGFloat = 0.5                   // the box around a pull quote, stroked inside

    // MARK: front page template (positions from the September 30 issue)

    enum Front {
        static let teaserPhoto = CGRect(x: 35.7, y: 48, width: 185.2, height: 62)
        static let teaserBar = CGRect(x: 239, y: 48.5, width: 527.2, height: 17.8)
        static let teaserColumns: [(x: CGFloat, width: CGFloat)] = [(240.9, 154.7), (417.0, 158.1), (597.5, 159.2)]
        static let nameplate = CGRect(x: 37.7, y: 129.1, width: 729, height: 117.6)
        static let teaserTop: CGFloat = 76.5                   // the teaser headlines, under the bar
        static let teaserTopThreeLines: CGFloat = 70           // started higher when a headline takes three lines
        static let teaserLabelInset: CGFloat = 4.5             // "Page 5" in the bar: in from the column's left edge
        static let teaserLabelBaseline: CGFloat = 62.8         // and its baseline
        static let datelineRight: CGFloat = 756
        static let datelineBaseline: CGFloat = 234.7
        static let leadTop: CGFloat = 251.6
        static let leadBottom: CGFloat = 735
        static let secondTop: CGFloat = 738.9
    }

    // MARK: the folio on inside pages (the Folio component is built from these)

    enum Folio {
        static let left: CGFloat = 40.3                        // "poly.rpi.edu"
        static let ruleLeft: CGFloat = 40.7
        static let right: CGFloat = 760.7                      // the desk and page number end here, and the rule
        static let rule: CGFloat = 53.3
        static let ruleWidth: CGFloat = 0.5
        static let baseline: CGFloat = 48.6
    }

    /// Dates and figures that shouldn't break across lines: "October 30th", "Nov. 12", "3 p.m.", "No. 7".
    static func keepTogether(_ s: String) -> String {
        let months = "January|February|March|April|May|June|July|August|September|October|November|December|Jan\\.|Feb\\.|Mar\\.|Apr\\.|Jun\\.|Jul\\.|Aug\\.|Sept?\\.|Oct\\.|Nov\\.|Dec\\."
        var t = s.replacingOccurrences(of: "\\b(\(months)) (\\d{1,2}(?:st|nd|rd|th)?)\\b", with: "$1\u{00A0}$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\b(\\d{1,2}) ([ap]\\.m\\.)", with: "$1\u{00A0}$2", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\b(No\\.|Nos\\.|Vol\\.|p\\.|pp\\.) (\\d)", with: "$1\u{00A0}$2", options: .regularExpression)
        return t
    }

    // MARK: measure

    /// Average advance of one character of body copy, measured on the copy itself.
    static func averageCharWidth(of text: String) -> CGFloat {
        let sample = text.count > 400 ? text : fallbackSample
        let s = NSAttributedString(string: sample, attributes: [.font: bodyFont])
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil)
        return CGFloat(width) / CGFloat(max(1, (sample as NSString).length))
    }

    /// The column count whose line length falls inside `lineLength`, nearest its middle.
    static func columns(averageCharWidth cw: CGFloat) -> (columns: Int, charsPerLine: Double) {
        let mid = (lineLength.lowerBound + lineLength.upperBound) / 2
        let options = (1...8).map { n in (n, Double(Grid(columns: n).colWidth / cw)) }
        let inside = options.filter { lineLength.contains($0.1) }
        return (inside.isEmpty ? options : inside).min { abs($0.1 - mid) < abs($1.1 - mid) }!
    }

    private static let fallbackSample = """
    The student senate met on Tuesday evening to consider a proposal that would change how club funding is \
    distributed across campus. Several members argued that the current system rewards the largest organizations, \
    while others said that any change should wait until the budget committee finishes its review next spring.
    """

    // MARK: jump lines

    /// The keyword for "See ROBOTICS, Page 7." — the first word of the headline that carries meaning.
    /// What the last block of an unfinished story ends with.
    static var onlineLine: String { Paper.onlineLine }    // "Read the rest at <the paper's website>."

    static func jumpWord(_ headline: String) -> String {
        let skip: Set<String> = ["a", "an", "the", "of", "and", "or", "for", "to", "in", "on", "at", "by", "with",
                                 "from", "new", "how", "why", "what", "as", "is", "are", "its", "it’s", "after", "over"]
        let words = Markup.plain(headline)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))) }
            .filter { !$0.isEmpty }
        let word = words.first { !skip.contains($0.lowercased()) && ($0.count >= 3 || $0 == $0.uppercased()) } ?? words.first ?? "Story"
        return word.uppercased()
    }
}

/// Columns across the live area of a page.
struct Grid: Hashable, Codable {
    var columns: Int

    var colWidth: CGFloat { (HouseStyle.liveWidth - CGFloat(columns - 1) * HouseStyle.gutter) / CGFloat(columns) }
    func x(_ column: Int) -> CGFloat { HouseStyle.margin + CGFloat(column) * (colWidth + HouseStyle.gutter) }
    func span(_ count: Int) -> CGFloat { CGFloat(count) * colWidth + CGFloat(max(0, count - 1)) * HouseStyle.gutter }

    /// Pull a frame's edges onto column edges when they come close.
    func snap(_ r: CGRect, threshold: CGFloat = 10) -> CGRect {
        var r = r
        for n in 1...columns where abs(span(n) - r.width) < threshold { r.size.width = span(n) }
        let lefts = (0..<columns).map { x($0) }
        let rights = lefts.map { $0 + colWidth }
        if let l = lefts.min(by: { abs($0 - r.minX) < abs($1 - r.minX) }), abs(l - r.minX) < threshold {
            r.origin.x = l
        } else if let e = rights.min(by: { abs($0 - r.maxX) < abs($1 - r.maxX) }), abs(e - r.maxX) < threshold {
            r.origin.x = e - r.width
        }
        return r
    }
}
