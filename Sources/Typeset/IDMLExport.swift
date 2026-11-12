import AppKit

/// Writes a composed issue as an IDML package (InDesign Markup Language): the open, documented interchange format
/// InDesign opens directly and saves as .indd. Each page becomes a spread. Every story block becomes a text frame
/// threaded through the story's blocks in reading order, set on a baseline grid at the story's leading, with the
/// headline, byline and jump line as frames of their own. Pictures go inside the package, embedded the way
/// InDesign embeds a link (the file's bytes, base64, in the image element), or as linked files in a Links folder
/// beside it. The copyfit travels with the text: a story's uniform setting as tracking, scaling, leading and
/// word-spacing overrides on its paragraphs, and each run set on its own as tracking on that run.
/// The package skeleton (document preferences, swatches, the font list, the empty master) comes from templates in
/// Resources/IDML, taken from the paper's own InDesign file, so the parts InDesign is fussy about are its own.
enum IDMLExport {
    enum Failure: Error, CustomStringConvertible {
        case noLayout, template(String), zip(String)
        var description: String {
            switch self {
            case .noLayout: "the issue has no pages"
            case .template(let n): "missing IDML template \(n)"
            case .zip(let m): "zip failed: \(m)"
            }
        }
    }

    /// Writes `url` (an .idml file); with `embedImages` false, a Links folder beside it holds the pictures instead.
    /// Returns the package's URL.
    @discardableResult
    static func write(_ issue: Issue, pages: [ComposedPage], composer: Composer, to url: URL, embedImages: Bool = true) throws -> URL {
        guard let w = IDMLWriter(issue: issue, pages: pages, composer: composer, package: url, embed: embedImages) else { throw Failure.noLayout }
        try w.build()
        return try w.package()
    }

    /// The template files InDesign wrote, used as they are.
    static func template(_ name: String) throws -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("IDML").appendingPathComponent(name),
              let s = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.template(name) }
        return s
    }
}

/// A component's frame (`Components.swift`), named apart from the writer's own text-frame record.
typealias ComponentFrame = Frame

private final class IDMLWriter {
    let issue: Issue
    let pages: [ComposedPage]
    let composer: Composer
    let layout: IssueLayout
    let articles: [Article.ID: Article]
    let extras: [Extra.ID: Extra]
    let packageURL: URL
    let linksDir: URL
    let embed: Bool

    private var counter = 0
    private var stories: [(id: String, xml: String)] = []
    private var spreads: [(id: String, pageID: String, xml: String)] = []

    /// A picture file the package links to, copied into Links/.
    struct Link {
        var name: String; var url: URL; var bounds: CGSize; var ppi: CGFloat?; var bytes: Int; var isPDF: Bool; var data: Data?
        var ext: String                 // the format InDesign gets: the file's own, or what it was converted to
        var converted = false           // HEIC, WebP and the like are written as JPEG or PNG
    }
    /// Formats InDesign places as they are. Anything else NSImage can read is converted on the way out.
    static let placeable: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "gif", "pdf"]
    private var links: [String: Link] = [:]
    private var linkNames: Set<String> = []

    init?(issue: Issue, pages: [ComposedPage], composer: Composer, package: URL, embed: Bool) {
        guard let layout = issue.layout, layout.pages.count == pages.count else { return nil }
        self.issue = issue; self.pages = pages; self.composer = composer; self.layout = layout; self.embed = embed
        articles = Dictionary(issue.articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extras = Dictionary(issue.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        packageURL = package
        linksDir = package.deletingLastPathComponent().appendingPathComponent("Links", isDirectory: true)
    }

    // MARK: ids, numbers, text

    private func id() -> String { counter += 1; return "g" + String(counter, radix: 16) }

    /// A number as IDML writes it: up to four decimals, no trailing zeros.
    private func f(_ v: CGFloat) -> String {
        var s = String(format: "%.4f", Double(v))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return s
    }

    private func esc(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r", "\u{2028}", "\u{2029}": out += " "
            default:
                if u.value < 0x20 && u != "\t" { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    // spread coordinates have their origin at the page's centre
    private var ox: CGFloat { HouseStyle.page.width / 2 }
    private var oy: CGFloat { HouseStyle.page.height / 2 }
    private func at(_ r: CGRect) -> String { "1 0 0 1 \(f(r.minX - ox)) \(f(r.minY - oy))" }

    private func point(_ x: CGFloat, _ y: CGFloat) -> String {
        let p = "\(f(x)) \(f(y))"
        return "<PathPointType Anchor=\"\(p)\" LeftDirection=\"\(p)\" RightDirection=\"\(p)\" />"
    }

    private func rectPath(_ w: CGFloat, _ h: CGFloat) -> String {
        "<Properties><PathGeometry><GeometryPathType PathOpen=\"false\"><PathPointArray>"
            + point(0, 0) + point(0, h) + point(w, h) + point(w, 0)
            + "</PathPointArray></GeometryPathType></PathGeometry></Properties>"
    }

    private func wrapXML(_ mode: String, _ top: CGFloat = 0, _ left: CGFloat = 0, _ bottom: CGFloat = 0, _ right: CGFloat = 0, side: String = "BothSides") -> String {
        "<TextWrapPreference Inverse=\"false\" ApplyToMasterPageOnly=\"false\" TextWrapSide=\"\(side)\" TextWrapMode=\"\(mode)\">"
            + "<Properties><TextWrapOffset Top=\"\(f(top))\" Left=\"\(f(left))\" Bottom=\"\(f(bottom))\" Right=\"\(f(right))\" /></Properties>"
            + "</TextWrapPreference>"
    }

    /// The wrap body text keeps around a picture, its caption or a pull quote (`Composer.wrap`).
    private var pictureWrap: Wrap { Wrap(mode: "BoundingBoxTextWrap", top: Composer.clearAbovePicture, left: HouseStyle.gutter, bottom: Composer.clearBelowPicture, right: HouseStyle.gutter) }
    struct Wrap { var mode: String; var top: CGFloat = 0; var left: CGFloat = 0; var bottom: CGFloat = 0; var right: CGFloat = 0; var side = "BothSides" }

    /// The body columns on the page being written, for fitting wraps to Typeset's rules.
    private var pageColumns: [CGRect] = []

    /// A wrap as InDesign must have it to leave the lines Typeset leaves.
    /// InDesign tests a line as the strip one leading tall ending at its baseline; Typeset as the same strip starting
    /// at the line's first-baseline offset above it, which ends about 3 pt below the baseline. The same obstacle
    /// therefore sits 3 pt higher for InDesign. And where a picture leaves less than half a column beside it, Typeset
    /// moves the line below rather than set a sliver; InDesign would set it, so the wrap covers the sliver.
    /// Text goes on the larger side only, as Typeset sets a line in the widest free span.
    private func fitted(_ wrap: Wrap, around r: CGRect) -> Wrap {
        var w = wrap
        w.top += slugShift
        w.bottom = max(0, w.bottom - slugShift)
        guard w.mode == "BoundingBoxTextWrap" else { return w }
        w.side = "LargestArea"
        let o = CGRect(x: r.minX - w.left, y: r.minY - w.top, width: r.width + w.left + w.right, height: r.height + w.top + w.bottom)
        for c in pageColumns where o.minX < c.maxX - 0.5 && o.maxX > c.minX + 0.5 && o.minY < c.maxY && o.maxY > c.minY {
            let free = max(o.minX - c.minX, c.maxX - o.maxX, 0)
            if free < c.width * 0.5 {
                if o.minX > c.minX { w.left += o.minX - c.minX }
                if o.maxX < c.maxX { w.right += c.maxX - o.maxX }
            }
        }
        return w
    }

    /// How far below its baseline Typeset's line strip reaches: the leading less the first-baseline offset.
    private var slugShift: CGFloat { HouseStyle.leading - bodyBaseline(leading: HouseStyle.leading) }

    private let common = "Visible=\"true\" Name=\"$ID/\" ItemLayer=\"ucc\" Locked=\"false\" LocalDisplaySetting=\"Default\""

    // MARK: page items

    private func fillRect(_ r: CGRect, color: String) -> String {
        "<Rectangle Self=\"\(id())\" ContentType=\"Unassigned\" StoryTitle=\"$ID/\" \(common) FillColor=\"\(color)\" StrokeWeight=\"0\" StrokeColor=\"Swatch/None\" "
            + "AppliedObjectStyle=\"ObjectStyle/$ID/[Normal Graphics Frame]\" ItemTransform=\"\(at(r))\">"
            + rectPath(r.width, r.height) + wrapXML("None") + "</Rectangle>"
    }

    private func line(from a: CGPoint, to b: CGPoint, weight: CGFloat, color: String = "Color/Black") -> String {
        "<GraphicLine Self=\"\(id())\" ContentType=\"Unassigned\" \(common) FillColor=\"Swatch/None\" StrokeColor=\"\(color)\" StrokeWeight=\"\(f(weight))\" "
            + "AppliedObjectStyle=\"ObjectStyle/$ID/[Normal Graphics Frame]\" ItemTransform=\"1 0 0 1 \(f(a.x - ox)) \(f(a.y - oy))\">"
            + "<Properties><PathGeometry><GeometryPathType PathOpen=\"true\"><PathPointArray>"
            + point(0, 0) + point(b.x - a.x, b.y - a.y)
            + "</PathPointArray></GeometryPathType></PathGeometry></Properties>" + wrapXML("None") + "</GraphicLine>"
    }

    struct Frame {
        var rect: CGRect
        var story: String
        var prev = "n", next = "n"
        var columns = 1
        var firstBaseline: CGFloat
        var inset: CGFloat = 0
        var ignoreWrap = true
        var wrap: Wrap?
        var grid: CGFloat?           // a baseline grid of its own: this increment, starting at the first baseline
        var stroke: CGFloat = 0
        var id: String?
        var gutter = HouseStyle.gutter   // a component's body frame sets in the component's own gutter
    }

    private func textFrame(_ fr: Frame) -> String {
        let r = fr.rect
        let colW = (r.width - CGFloat(fr.columns - 1) * fr.gutter) / CGFloat(fr.columns)
        let stroke = fr.stroke > 0
            ? "StrokeWeight=\"\(f(fr.stroke))\" StrokeColor=\"Color/Black\" StrokeAlignment=\"InsideAlignment\""
            : "StrokeWeight=\"0\" StrokeColor=\"Swatch/None\""
        var x = "<TextFrame Self=\"\(fr.id ?? id())\" ParentStory=\"\(fr.story)\" PreviousTextFrame=\"\(fr.prev)\" NextTextFrame=\"\(fr.next)\" ContentType=\"TextType\" "
            + "\(common) FillColor=\"Swatch/None\" \(stroke) AppliedObjectStyle=\"ObjectStyle/$ID/[Normal Text Frame]\" ItemTransform=\"\(at(r))\">"
        x += rectPath(r.width, max(1, r.height))
        x += "<TextFramePreference TextColumnCount=\"\(fr.columns)\" TextColumnGutter=\"\(f(fr.gutter))\" TextColumnFixedWidth=\"\(f(colW))\" UseFixedColumnWidth=\"false\" "
            + "FirstBaselineOffset=\"FixedHeight\" MinimumFirstBaselineOffset=\"\(f(fr.firstBaseline))\" VerticalJustification=\"TopAlign\" IgnoreWrap=\"\(fr.ignoreWrap)\">"
            + "<Properties><InsetSpacing type=\"list\">" + String(repeating: "<ListItem type=\"unit\">\(f(fr.inset))</ListItem>", count: 4) + "</InsetSpacing></Properties>"
            + "</TextFramePreference>"
        if let g = fr.grid {
            x += "<BaselineFrameGridOption UseCustomBaselineFrameGrid=\"true\" StartingOffsetForBaselineFrameGrid=\"\(f(fr.firstBaseline))\" "
                + "BaselineFrameGridRelativeOption=\"TopOfInset\" BaselineFrameGridIncrement=\"\(f(g))\" />"
        }
        if let w = fr.wrap { x += wrapXML(w.mode, w.top, w.left, w.bottom, w.right, side: w.side) } else { x += wrapXML("None") }
        return x + "</TextFrame>"
    }

    /// A linked picture file. Pictures come in cropped to fill the frame (as photos run) or fit whole (as ads do).
    private func picture(_ r: CGRect, path: String, stroke: CGFloat, fill: Bool, wrap: Wrap?, stretch: Bool = false,
                         focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> String {
        let strokeAttrs = stroke > 0
            ? "StrokeWeight=\"\(f(stroke))\" StrokeColor=\"Color/Black\" StrokeAlignment=\"InsideAlignment\""
            : "StrokeWeight=\"0\" StrokeColor=\"Swatch/None\""
        var x = "<Rectangle Self=\"\(id())\" ContentType=\"GraphicType\" StoryTitle=\"$ID/\" \(common) FillColor=\"Swatch/None\" \(strokeAttrs) "
            + "AppliedObjectStyle=\"ObjectStyle/$ID/[None]\" ItemTransform=\"\(at(r))\">" + rectPath(r.width, r.height)
        x += "<FrameFittingOption AutoFit=\"false\" LeftCrop=\"0\" TopCrop=\"0\" RightCrop=\"0\" BottomCrop=\"0\" FittingOnEmptyFrame=\"\(fill ? "FillProportionally" : "Proportionally")\" FittingAlignment=\"CenterAnchor\" />"
        if let w = wrap { x += wrapXML(w.mode, w.top, w.left, w.bottom, w.right, side: w.side) } else { x += wrapXML("None") }
        if let l = link(path), l.bounds.width > 0, l.bounds.height > 0 {
            let s = fill ? max(r.width / l.bounds.width, r.height / l.bounds.height) : min(r.width / l.bounds.width, r.height / l.bounds.height)
            let sx = stretch ? r.width / l.bounds.width : s, sy = stretch ? r.height / l.bounds.height : s
            // the crop Typeset shows: the hidden span slides with the focus (centred for a picture fitted whole)
            let fx = fill ? focus.x : 0.5, fy = fill ? focus.y : 0.5
            let tx = (r.width - l.bounds.width * sx) * fx, ty = (r.height - l.bounds.height * sy) * fy
            let transform = "\(f(sx)) 0 0 \(f(sy)) \(f(tx)) \(f(ty))"
            var props = "<GraphicBounds Left=\"0\" Top=\"0\" Right=\"\(f(l.bounds.width))\" Bottom=\"\(f(l.bounds.height))\" />"
            if embed, let data = l.data { props += "<Contents><![CDATA[\(data.base64EncodedString())]]></Contents>" }       // the file itself, as InDesign embeds a link
            let bounds = "<Properties>\(props)</Properties>"
            if l.isPDF {
                x += "<PDF Self=\"\(id())\" OverriddenPageItemProps=\"\" LocalDisplaySetting=\"Default\" ImageTypeName=\"$ID/Adobe PDF\" AppliedObjectStyle=\"ObjectStyle/$ID/[None]\" "
                    + "ItemTransform=\"\(transform)\" Visible=\"true\" Name=\"$ID/\">" + bounds
                    + "<PDFAttribute PageNumber=\"1\" PDFCrop=\"CropMedia\" TransparentBackground=\"true\" />"
                    + wrapXML("None") + linkXML(l) + "</PDF>"
            } else {
                let ppi = l.ppi ?? 72
                x += "<Image Self=\"\(id())\" Space=\"$ID/#Links_RGB\" ActualPpi=\"\(f(ppi)) \(f(ppi))\" EffectivePpi=\"\(f(ppi / s)) \(f(ppi / s))\" ImageRenderingIntent=\"UseColorSettings\" "
                    + "OverriddenPageItemProps=\"\" LocalDisplaySetting=\"Default\" ImageTypeName=\"$ID/\(Self.formatName(l.ext))\" "
                    + "AppliedObjectStyle=\"ObjectStyle/$ID/[None]\" ItemTransform=\"\(transform)\" Visible=\"true\" Name=\"$ID/\">" + bounds
                    + "<ClippingPathSettings ClippingType=\"None\" InvertPath=\"false\" IncludeInsideEdges=\"false\" RestrictToFrame=\"false\" UseHighResolutionImage=\"true\" Threshold=\"25\" Tolerance=\"2\" InsetFrame=\"0\" AppliedPathName=\"$ID/\" Index=\"-1\" />"
                    + "<ImageIOPreference ApplyPhotoshopClippingPath=\"true\" AllowAutoEmbedding=\"true\" AlphaChannelName=\"$ID/\" />"
                    + wrapXML("None") + linkXML(l) + "</Image>"
            }
        }
        return x + "</Rectangle>"
    }

    private static func formatName(_ ext: String) -> String {
        switch ext {
        case "pdf": "Adobe PDF"
        case "png": "Portable Network Graphics (PNG)"
        case "tif", "tiff": "TIFF"
        case "gif": "GIF"
        default: "JPEG"
        }
    }

    private func linkXML(_ l: Link) -> String {
        let format = Self.formatName(l.ext)
        // a converted picture has no file of its own outside the package, so its link names the one in Links
        let path = embed && !l.converted ? l.url.path : linksDir.appendingPathComponent(l.name).path
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        let stamp = df.string(from: Date())
        return "<Link Self=\"\(id())\" AssetURL=\"$ID/\" AssetID=\"$ID/\" LinkResourceURI=\"\(esc(uri))\" LinkResourceFormat=\"$ID/\(format)\" StoredState=\"\(embed ? "Embedded" : "Normal")\" "
            + "LinkClassID=\"35906\" LinkClientID=\"257\" LinkResourceModified=\"false\" LinkObjectModified=\"false\" ShowInUI=\"true\" CanEmbed=\"true\" CanUnembed=\"true\" CanPackage=\"true\" "
            + "ImportPolicy=\"NoAutoImport\" ExportPolicy=\"NoAutoExport\" LinkImportStamp=\"file 0 \(l.bytes)\" LinkImportModificationTime=\"\(stamp)\" LinkImportTime=\"\(stamp)\" "
            + "LinkResourceSize=\"0~\(String(l.bytes, radix: 16))\" RenditionData=\"Actual\" PDFIdentifier=\"0\" SourceObjectName=\"\" />"
    }

    /// The file behind a picture path, as InDesign will see it: its size in points and resolution.
    private func link(_ path: String) -> Link? {
        if let l = links[path] { return l }
        guard let url = IssueStore.imageURL(for: path), FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        let isPDF = url.pathExtension.lowercased() == "pdf"
        var bounds = img.size
        var ppi: CGFloat?
        if !isPDF, let rep = img.representations.first, rep.pixelsWide > 0, rep.size.width > 0 {
            bounds = rep.size
            ppi = CGFloat(rep.pixelsWide) / rep.size.width * 72
        }
        var name = url.lastPathComponent
        if name.hasPrefix("seed:") { name = String(name.dropFirst(5)) }
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while linkNames.contains(name) { name = "\(base)-\(n).\(ext)"; n += 1 }
        linkNames.insert(name)
        var bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var l = Link(name: name, url: url, bounds: bounds, ppi: ppi, bytes: bytes, isPDF: isPDF,
                     data: embed ? try? Data(contentsOf: url) : nil, ext: ext.lowercased())
        if !Self.placeable.contains(ext.lowercased()) {
            // an iPhone HEIC, a WebP, a PSD…: InDesign can't place it, so it goes as JPEG (or PNG, to keep transparency)
            guard let (data, newExt) = Self.convert(img) else { return nil }
            l.data = data; l.ext = newExt; l.converted = true
            bytes = data.count; l.bytes = bytes
            linkNames.remove(name)
            var conv = "\(base).\(newExt)"; var k = 2
            while linkNames.contains(conv) { conv = "\(base)-\(k).\(newExt)"; k += 1 }
            linkNames.insert(conv)
            l.name = conv
        }
        links[path] = l
        return l
    }

    /// A picture re-encoded for InDesign: PNG when it has transparency, JPEG otherwise.
    private static func convert(_ img: NSImage) -> (Data, String)? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if rep.hasAlpha, let png = rep.representation(using: .png, properties: [:]) { return (png, "png") }
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }
        return (jpg, "jpg")
    }

    // MARK: stories

    struct Run {
        var text: String
        var fontStyle: String?
        var tracking: CGFloat = 0           // 1/1000 em
        var scale: CGFloat = 100            // horizontal scale, per cent
        var leading: CGFloat?
        var noBreak = false
    }
    struct Para { var style: String; var attrs: [String: String] = [:]; var runs: [Run] }

    private func story(_ sid: String, _ paras: [Para]) {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<idPkg:Story xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"21.5\">\n"
            + "\t<Story Self=\"\(sid)\" UserText=\"true\" IsEndnoteStory=\"false\" AppliedTOCStyle=\"n\" TrackChanges=\"false\" StoryTitle=\"$ID/\" AppliedNamedGrid=\"n\">\n"
            + "\t\t<StoryPreference OpticalMarginAlignment=\"false\" OpticalMarginSize=\"12\" FrameType=\"TextFrameType\" StoryOrientation=\"Horizontal\" StoryDirection=\"LeftToRightDirection\" />\n"
            + "\t\t<InCopyExportOption IncludeGraphicProxies=\"true\" IncludeAllResources=\"false\" />\n"
        let paras = paras.filter { !$0.runs.isEmpty }
        for (i, p) in paras.enumerated() {
            // character attributes (point size) go on every run: InDesign ignores them on the paragraph range
            let charKeys: Set<String> = ["PointSize", "FillColor"]
            let attrs = p.attrs.filter { !charKeys.contains($0.key) }.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(esc($0.value))\"" }.joined()
            let charAttrs = p.attrs.filter { charKeys.contains($0.key) }.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(esc($0.value))\"" }.joined()
            x += "\t\t<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/\(esc(p.style))\"\(attrs)>\n"
            for (k, r) in p.runs.enumerated() {
                var a = charAttrs
                if let s = r.fontStyle { a += " FontStyle=\"\(s)\"" }
                if abs(r.tracking) >= 0.005 { a += " Tracking=\"\(f((r.tracking * 100).rounded() / 100))\"" }
                if abs(r.scale - 100) >= 0.005 { a += " HorizontalScale=\"\(f((r.scale * 100).rounded() / 100))\"" }
                if r.noBreak { a += " NoBreak=\"true\"" }
                x += "\t\t\t<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\"\(a)>"
                if let l = r.leading { x += "<Properties><Leading type=\"unit\">\(f(l))</Leading></Properties>" }
                x += "<Content>\(esc(r.text))</Content>"
                if k == p.runs.count - 1, i < paras.count - 1 { x += "<Br />" }
                x += "</CharacterStyleRange>\n"
            }
            x += "\t\t</ParagraphStyleRange>\n"
        }
        x += "\t</Story>\n</idPkg:Story>\n"
        stories.append((sid, x))
    }

    /// A headline's runs: the plain words, and any *title* in the family's bold italic.
    private func headlineRuns(_ markup: String, size: CGFloat) -> [Run] {
        let att = Composer.headline(markup: markup, size: size)
        var runs: [Run] = []
        att.enumerateAttribute(.font, in: NSRange(location: 0, length: att.length)) { value, range, _ in
            let italic = ((value as? NSFont)?.fontName ?? "").contains("It")
            runs.append(Run(text: (att.string as NSString).substring(with: range), fontStyle: italic ? "Bold Italic" : nil, leading: size * 1.04))
        }
        return runs
    }

    private func simpleStory(_ style: String, _ text: String, attrs: [String: String] = [:], fontStyle: String? = nil, leading: CGFloat? = nil) -> String {
        let sid = id()
        story(sid, [Para(style: style, attrs: attrs, runs: [Run(text: text, fontStyle: fontStyle, leading: leading)])])
        return sid
    }

    private func em(_ points: CGFloat) -> CGFloat { points / HouseStyle.bodySize * 1000 }

    /// How far TextKit lets a hyphenated line run past its column, in points (measured: up to about 0.23).
    static let hyphenOverhang: CGFloat = 0.3

    /// The width of a space in the body face, as TextKit sets it.
    private func spaceAdvance(_ style: String?) -> CGFloat {
        let name = ["Italic": "MinionPro-It", "Bold": "MinionPro-Bold", "Bold Italic": "MinionPro-BoldIt"][style ?? ""] ?? "MinionPro-Regular"
        return (" " as NSString).size(withAttributes: [.font: HouseStyle.font(name, HouseStyle.bodySize)]).width
    }

    /// A setting's word spacing as InDesign's justification settings. Minimum, desired and maximum are all Typeset's
    /// value: Typeset's composer fills a line at that spacing and only ever stretches it to justify, so InDesign must
    /// not squeeze spaces to take another word, and with nothing "within limits" to prefer it takes the hyphenation
    /// point Typeset took rather than stretching instead.
    private func wordSpacing(_ fit: Fit) -> [String: String] {
        guard abs(fit.wordSpace) > 0.001 else { return [:] }
        let v = f(CGFloat(100 + 100 * Double(fit.wordSpace)))
        return ["MinimumWordSpacing": v, "DesiredWordSpacing": v, "MaximumWordSpacing": v]
    }

    private func fontStyle(_ font: NSFont?) -> String? {
        let n = font?.fontName ?? ""
        if n.contains("BoldIt") { return "Bold Italic" }
        if n.hasSuffix("-It") || n.contains("Italic") { return "Italic" }
        if n.contains("Bold") { return "Bold" }
        return nil
    }

    /// A story's body as one IDML story: its paragraphs with their italic and bold runs, the copyfit as overrides,
    /// and "Continued from Page N." set in italics where each later block takes it up.
    private func bodyStory(_ a: Article, blocks: [(page: Int, block: StoryBlock)]) -> String {
        let sid = id()
        let fit = composer.settings[a.id] ?? .neutral
        let att = composer.body(a)
        let ns = att.string as NSString
        var inserts: [Int: String] = [:]
        var hyphens: Set<Int> = []
        /// A block's result, a component frame's included (keyed there by placement and frame).
        func result(_ page: Int, _ id: StoryBlock.ID) -> Composer.BlockResult? {
            if let r = pages[page].blockResults[id] { return r }
            for (placed, frames) in pages[page].componentBlockResults {
                for (frame, r) in frames where Composer.blockID(placed: placed, frame: frame) == id { return r }
            }
            return nil
        }
        for (k, item) in blocks.enumerated() {
            guard let r = result(item.page, item.block.id) else { continue }
            hyphens.formUnion(r.hyphens)
            if k > 0, let from = r.continuedFrom, r.start < r.total { inserts[r.start] = "Continued from Page \(from). " }
        }
        // a discretionary hyphen (U+00AD) wherever Typeset broke a word, and automatic hyphenation off in the Body
        // style, so InDesign hyphenates exactly where Typeset did
        let leading: CGFloat? = abs(fit.leading - HouseStyle.leading) > 0.01 ? fit.leading : nil
        func digit(_ k: Int) -> Bool { k < ns.length && (0x30...0x39).contains(ns.character(at: k)) }      // an ASCII digit; safe on surrogates
        // A space as wide as Typeset sets it. TextKit scales a space's glyph but adds tracking and the word-space
        // change unscaled, where InDesign takes word spacing as a share of the space and may scale its tracking.
        // A space run at 100% with the difference as tracking comes out the same in both, whatever InDesign does
        func space(_ style: String?, glyphScale: CGFloat, trackingPts: CGFloat, wordSpacePts: CGFloat, paraWordSpace: CGFloat) -> Run {
            let sw = spaceAdvance(style)
            let t = sw * glyphScale + trackingPts + wordSpacePts - sw * (1 + paraWordSpace)
            return Run(text: " ", fontStyle: style, tracking: em(t), scale: 100, leading: leading)
        }
        var paras: [Para] = []
        for (i, r) in Composer.paragraphRanges(att.string).enumerated() where r.length > 0 {
            var cuts: Set<Int> = [r.location, NSMaxRange(r)]
            att.enumerateAttribute(.font, in: r, options: []) { _, rr, _ in cuts.insert(rr.location); cuts.insert(NSMaxRange(rr)) }
            // a run set on its own is the end of a paragraph from `from`, or all of it. A whole paragraph is set the
            // way the story's uniform level is, as overrides on the paragraph; the end of one keeps Typeset's own
            // model, each space carrying its share of the word-space change as tracking, so the lines break alike
            var paraFit = fit
            var tail = fit.local[i].flatMap { $0.from < r.length ? (start: r.location + $0.from, fit: Fit(level: $0.level)) : nil }
            if let t = tail, t.start == r.location { paraFit = t.fit; tail = nil }
            if let t = tail { cuts.insert(t.start) }
            let scaled = abs(paraFit.glyphScale - 1) > 0.0005
            for k in r.location..<NSMaxRange(r) where ns.character(at: k) == 0x20 && (scaled || tail.map { k >= $0.start } ?? false) {
                cuts.insert(k); cuts.insert(k + 1)
            }
            // Typeset's hyphenation points, each its own run: TextKit draws the hyphen scaled but untracked
            for h in hyphens where h > r.location && h < NSMaxRange(r) { cuts.insert(h) }
            // places Typeset never breaks (Unicode line breaking) and InDesign would: a hyphen before a digit ("7-3",
            // "38-14") and a space before an apostrophe that starts a word ("Li ’30"). Those characters are kept
            // together with No Break
            var together: Set<Int> = []
            for k in (r.location + 1)..<max(r.location + 1, NSMaxRange(r) - 1)
            where (ns.character(at: k) == 0x2D && digit(k + 1)) || (ns.character(at: k) == 0x20 && ns.character(at: k + 1) == 0x2019) {
                for j in (k - 1)...(k + 1) { together.insert(j); cuts.insert(j); cuts.insert(j + 1) }
            }
            for pos in inserts.keys where pos > r.location && pos < NSMaxRange(r) { cuts.insert(pos) }
            let sorted = cuts.sorted()
            // where a later block takes the story up, the paragraph is split: the part before is justified to its
            // last line (it is mid-paragraph, as Typeset sets it) and the rest starts in the next frame, indented,
            // with "Continued from Page N.", so the frame break lands where Typeset's block break did
            var attrs = wordSpacing(paraFit)
            if i == 0 { attrs["FirstLineIndent"] = "0" }          // a story's first paragraph is flush left
            var runs: [Run] = []
            for (lo, hi) in zip(sorted, sorted.dropFirst()) where hi > lo {
                if let lead = inserts[lo] {
                    if lo > r.location {
                        if var last = runs.popLast() {
                            while last.text.hasSuffix(" ") { last.text.removeLast() }
                            if !last.text.isEmpty { runs.append(last) }
                        }
                        var before = attrs; before["Justification"] = "FullyJustified"
                        paras.append(Para(style: "Body", attrs: before, runs: runs))
                        runs = []
                    }
                    attrs["StartParagraph"] = "NextFrame"
                    attrs["FirstLineIndent"] = nil                  // the rest, after "Continued from", is indented
                    // set as Typeset sets it: the story's tracking and scale, spaces without the word-space change
                    for (k, word) in lead.components(separatedBy: " ").enumerated() {
                        if k > 0 {
                            runs.append(space("Italic", glyphScale: fit.glyphScale, trackingPts: fit.tracking, wordSpacePts: 0, paraWordSpace: paraFit.wordSpace))
                        }
                        if !word.isEmpty { runs.append(Run(text: word, fontStyle: "Italic", tracking: em(fit.tracking), scale: fit.glyphScale * 100, leading: leading)) }
                    }
                }
                let level = tail.map { lo >= $0.start ? $0.fit : paraFit } ?? paraFit
                let style = fontStyle(att.attribute(.font, at: lo, effectiveRange: nil) as? NSFont)
                if hyphens.contains(lo) {
                    // TextKit adds no tracking to the hyphen it sets, and lets a hyphenated line overhang the column
                    // by up to about a quarter point. The hyphen's run gives InDesign the same allowance as negative
                    // tracking, which only moves the empty space after a hyphen that ends a line
                    runs.append(Run(text: "\u{00AD}", fontStyle: style, tracking: em(-Self.hyphenOverhang), scale: level.glyphScale * 100, leading: leading))
                }
                let piece = ns.substring(with: NSRange(location: lo, length: hi - lo))
                if piece == " ", scaled || level != paraFit {
                    var sp = space(style, glyphScale: level.glyphScale, trackingPts: level.tracking,
                                   wordSpacePts: level.wordSpace * Composer.spaceWidth, paraWordSpace: paraFit.wordSpace)
                    sp.noBreak = together.contains(lo)
                    runs.append(sp)
                } else {
                    runs.append(Run(text: piece, fontStyle: style, tracking: em(level.tracking) / level.glyphScale, scale: level.glyphScale * 100,
                                    leading: leading, noBreak: together.contains(lo)))
                }
            }
            paras.append(Para(style: "Body", attrs: attrs, runs: runs))
        }
        story(sid, paras)
        return sid
    }

    // MARK: measuring, so the first baseline lands where Typeset's does

    private func firstBaseline(_ s: NSAttributedString, width: CGFloat, pitch: CGFloat? = nil) -> CGFloat {
        guard s.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = FlowContainer(size: CGSize(width: max(width, 10), height: 1e6))
        tc.lineFragmentPadding = 0
        tc.pitch = pitch
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        guard lm.numberOfGlyphs > 0 else { return 0 }
        return lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + lm.location(forGlyphAt: 0).y
    }

    private var bodyBaselines: [CGFloat: CGFloat] = [:]
    private func bodyBaseline(leading: CGFloat) -> CGFloat {
        if let b = bodyBaselines[leading] { return b }
        let s = NSAttributedString(string: "Xg", attributes: [.font: HouseStyle.bodyFont, .paragraphStyle: Composer.bodyStyle(leading: leading)])
        let b = firstBaseline(s, width: 300, pitch: leading)
        bodyBaselines[leading] = b
        return b
    }

    // MARK: pages

    func build() throws {
        var appearances: [Article.ID: [(page: Int, block: StoryBlock)]] = [:]
        // a story set in a component's body or whole-story frame threads with its blocks, in the composer's order
        let inFrames = layout.pages.map { composer.componentBlocks(on: $0, issue: issue, pageColumns: layout.columns, articles: articles) }
        for (i, p) in layout.pages.enumerated() {
            for b in PageLayout.readingOrder(p.stories + inFrames[i].map(\.block)) { appearances[b.article, default: []].append((i, b)) }
        }
        var frameIDs: [StoryBlock.ID: String] = [:]
        for list in appearances.values { for item in list { frameIDs[item.block.id] = id() } }
        var bodyStories: [Article.ID: String] = [:]
        for (aid, list) in appearances.sorted(by: { $0.value[0].page < $1.value[0].page || ($0.value[0].page == $1.value[0].page && $0.value[0].block.frame.y < $1.value[0].block.frame.y) }) {
            guard let a = articles[aid] else { continue }
            bodyStories[aid] = bodyStory(a, blocks: list)
        }
        let firstPage = appearances.mapValues { $0[0].page + 1 }
        var threads: [StoryBlock.ID: (prev: String, next: String)] = [:]
        for list in appearances.values {
            for (k, item) in list.enumerated() {
                threads[item.block.id] = (k > 0 ? frameIDs[list[k - 1].block.id]! : "n", k + 1 < list.count ? frameIDs[list[k + 1].block.id]! : "n")
            }
        }
        for (i, page) in layout.pages.enumerated() {
            spread(index: i, page: page, composed: pages[i], inFrames: inFrames[i], frameIDs: frameIDs, threads: threads, bodyStories: bodyStories, firstPage: firstPage)
        }
    }

    private func spread(index i: Int, page: PageLayout, composed cp: ComposedPage, inFrames: [Composer.ComponentBlock], frameIDs: [StoryBlock.ID: String],
                        threads: [StoryBlock.ID: (prev: String, next: String)], bodyStories: [Article.ID: String], firstPage: [Article.ID: Int]) {
        let spreadID = id(), pageID = id()
        var under: [String] = []       // fills and rules
        var text: [String] = []        // body and headline frames
        var over: [String] = []        // pictures and the small frames with wraps, above the text they push

        // the page's components (the front's Header, the inside pages' Folio, any other), under the stories, where
        // the composer draws them too
        components(page, number: i + 1, section: cp.section, firstPage: firstPage, into: &under)

        let obs = composer.obstacles(page, articles: articles)
        let aligned = composer.alignedBodyTops(page, articles: articles, obs)
        pageColumns = page.stories.flatMap { b -> [CGRect] in
            let f = b.frame.rect
            let w = (f.width - CGFloat(b.columns - 1) * HouseStyle.gutter) / CGFloat(b.columns)
            return (0..<b.columns).map { CGRect(x: f.minX + CGFloat($0) * (w + HouseStyle.gutter), y: f.minY, width: w, height: f.height) }
        }
        for b in PageLayout.readingOrder(page.stories + inFrames.map(\.block)) {
            guard let a = articles[b.article], let bodyID = bodyStories[a.id], let frameID = frameIDs[b.id] else { continue }
            let inside = inFrames.first { $0.block.id == b.id }          // a component's body or whole-story frame
            let frame = b.frame.rect
            let fit = composer.settings[a.id] ?? .neutral
            let avoid = inside.map { composer.avoid(forComponentBlock: $0, obs) } ?? composer.avoid(for: b, on: page, obs)
            let g = composer.blockGeometry(a, frame: frame, columns: b.columns, headlineSize: b.headlineSize, avoid: avoid, bylineColumns: b.bylineColumns,
                                           bodyTop: aligned[b.id], draw: true, gutter: inside?.gutter ?? HouseStyle.gutter, bodyOnly: inside?.bodyOnly ?? false)
            let r = inside.map { cp.componentBlockResults[$0.placed]?[$0.frame] } ?? cp.blockResults[b.id]
            // the kicker: small bold capitals over the headline (no rule under it)
            if let k = g.kicker, !a.kicker.trimmed.isEmpty {
                let sid = fieldStory(Composer.kicker(a.kicker.trimmed), style: "Folio", attrs: ["PointSize": f(HouseStyle.kickerSize)],
                                     leading: 12, tracking: 120)
                text.append(textFrame(Frame(rect: CGRect(x: k.minX, y: k.minY, width: k.width, height: 13), story: sid, firstBaseline: 9.5, ignoreWrap: true)))
            }
            let thread = threads[b.id] ?? ("n", "n")
            // the body: threaded, on its own grid at the story's leading
            let body = CGRect(x: frame.minX, y: g.bodyTop, width: frame.width, height: max(1, frame.maxY - g.bodyTop))
            text.append(textFrame(Frame(rect: body, story: bodyID, prev: thread.prev, next: thread.next, columns: b.columns,
                                        firstBaseline: bodyBaseline(leading: fit.leading), ignoreWrap: false, grid: fit.leading, id: frameID,
                                        gutter: inside?.gutter ?? HouseStyle.gutter)))
            // the headline across the top of the block (a body frame has none)
            let head = inside?.bodyOnly == true ? "" : a.plainHeadline.trimmed
            let headTop = g.headTop + (g.kicker?.height ?? 0)
            if !head.isEmpty, g.bodyTop - headTop > HouseStyle.headlineGap {
                let used = g.bodyTop - headTop - HouseStyle.headlineGap
                let sid = id()
                let hs = g.headlineSize > 0 ? g.headlineSize : b.headlineSize   // smaller when a picture is in its way
                story(sid, [Para(style: "Headline", attrs: ["PointSize": f(hs)], runs: headlineRuns(a.headline.trimmed, size: hs))])
                let b0 = firstBaseline(Composer.headline("Xg", size: hs), width: frame.width)
                // body text keeps 8 pt clear above a picture and 10 below; display type only 4. A picture snapped
                // to the byline rule would catch the headline's frame by that difference, so the headline only
                // minds wraps when a picture really is in its band, the test Typeset's composer makes
                let band = CGRect(x: frame.minX, y: headTop, width: frame.width, height: used)
                let inTheWay = avoid.contains {
                    CGRect(x: $0.minX, y: $0.minY + 8 - Composer.displayClearance, width: $0.width,
                           height: max(1, $0.height - (Composer.clearAbovePicture - Composer.displayClearance) - (Composer.clearBelowPicture - Composer.displayClearance))).intersects(band)
                }
                text.append(textFrame(Frame(rect: CGRect(x: frame.minX, y: headTop, width: frame.width, height: used), story: sid,
                                            firstBaseline: b0, ignoreWrap: !inTheWay)))
            }
            // the byline between its rules; the body keeps 4 pt clear below it
            if let by = g.byline {
                let name = drawnBaseline(a.author.trimmed, face: "Raleway-SemiBold", size: 12, baseline: 14.8)
                let title = drawnBaseline(a.authorTitle.trimmed, face: "MyriadPro-It", size: 10, baseline: 29.1)
                // the names as Typeset wrapped them, so InDesign breaks the same lines (at "and", not mid-name)
                let lines = Composer.bylineLines(a.author.trimmed, width: by.width)
                var paras = lines.enumerated().flatMap { i, l in
                    fieldParas(Composer.marked(l, [.font: HouseStyle.font("Raleway-SemiBold", 12)]), style: "Byline",
                               leading: i == 0 ? name : HouseStyle.bylineLeading)
                }
                if !a.authorTitle.trimmed.isEmpty {
                    paras += fieldParas(Composer.marked(a.authorTitle.trimmed, [.font: HouseStyle.font("MyriadPro-It", 10)]), style: "Byline Title", leading: title - name)
                }
                let sid = id(); story(sid, paras)
                under.append(line(from: CGPoint(x: by.minX, y: by.minY), to: CGPoint(x: by.maxX, y: by.minY), weight: 0.5))
                under.append(line(from: CGPoint(x: by.minX, y: by.maxY), to: CGPoint(x: by.maxX, y: by.maxY), weight: 0.5))
                over.append(textFrame(Frame(rect: by, story: sid, firstBaseline: name, wrap: fitted(Wrap(mode: "BoundingBoxTextWrap", bottom: 4), around: by))))
            }
            // the jump line in the last column's last slot; the body jumps over it
            if let r, r.jumped || r.online {
                let line = r.jumped ? "See \(a.jumpWord), Page \(r.jumpTo ?? 0)." : HouseStyle.onlineLine
                let sid = simpleStory("Jump Line", line)
                let j = g.jump
                let jr = CGRect(x: j.minX, y: j.minY, width: j.width, height: j.height + 5)
                over.append(textFrame(Frame(rect: jr, story: sid, firstBaseline: j.height - 2, wrap: fitted(Wrap(mode: "JumpObjectTextWrap"), around: jr))))
            }
        }

        for rule in Composer.storyRules(page, results: cp.blockResults, around: obs.geoms.values.map(\.full)) {
            under.append(line(from: rule.from, to: rule.to, weight: HouseStyle.storyRule))
        }

        for inset in page.insets {
            guard let g = composer.geometry(inset, inset.article.flatMap { articles[$0] }, inset.extra.flatMap { extras[$0] }) else { continue }
            switch inset.kind {
            case .photo:
                let path = inset.article.flatMap { articles[$0] }?.photos.first(where: { $0.id == inset.photo })?.path ?? ""
                over.append(picture(g.picture, path: path, stroke: HouseStyle.photoOutline, fill: true, wrap: fitted(pictureWrap, around: g.picture), focus: inset.focus))
                if let t = g.text, let tr = g.textRect { over.append(caption(t, in: tr)) }
            case .extra:
                guard let e = inset.extra.flatMap({ extras[$0] }) else { continue }
                over.append(picture(g.picture, path: e.path, stroke: HouseStyle.photoOutline, fill: false, wrap: fitted(pictureWrap, around: g.picture)))
                if let t = g.text, let tr = g.textRect { over.append(caption(t, in: tr)) }
            case .pullQuote:
                guard let t = g.text, let tr = g.textRect else { continue }
                let size: CGFloat = g.picture.width >= 300 ? 20 : 17
                let sid = fieldStory(t, style: "Pull Quote", attrs: ["PointSize": f(size)], leading: size * 1.2)
                let b0 = firstBaseline(t, width: tr.width) - 2
                over.append(textFrame(Frame(rect: g.picture, story: sid, firstBaseline: b0, inset: 10, wrap: fitted(pictureWrap, around: g.picture), stroke: HouseStyle.pullQuoteRule)))
            }
        }

        let grid = layout.grid
        var positions: [String] = []
        for c in 0..<grid.columns { positions.append(f(grid.x(c) - HouseStyle.margin)); positions.append(f(grid.x(c) + grid.colWidth - HouseStyle.margin)) }
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<idPkg:Spread xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"21.5\">\n"
            + "\t<Spread Self=\"\(spreadID)\" PageTransitionType=\"None\" PageTransitionDirection=\"NotApplicable\" PageTransitionDuration=\"Medium\" ShowMasterItems=\"true\" "
            + "PageCount=\"1\" BindingLocation=\"0\" SpreadHidden=\"false\" AllowPageShuffle=\"true\" ItemTransform=\"1 0 0 1 0 0\" FlattenerOverride=\"Default\">\n"
            + "\t\t<Page Self=\"\(pageID)\" TabOrder=\"\" AppliedMaster=\"ud6\" OverrideList=\"\" MasterPageTransform=\"1 0 0 1 0 0\" Name=\"\(i + 1)\" "
            + "AppliedTrapPreset=\"TrapPreset/$ID/kDefaultTrapStyleName\" GeometricBounds=\"0 0 \(f(HouseStyle.page.height)) \(f(HouseStyle.page.width))\" "
            + "ItemTransform=\"1 0 0 1 \(f(-ox)) \(f(-oy))\" LayoutRule=\"UseMaster\" SnapshotBlendingMode=\"IgnoreLayoutSnapshots\" OptionalPage=\"false\" GridStartingPoint=\"TopOutside\" UseMasterGrid=\"true\">\n"
            + "\t\t\t<Properties><PageColor type=\"enumeration\">UseMasterColor</PageColor></Properties>\n"
            + "\t\t\t<MarginPreference ColumnCount=\"\(grid.columns)\" ColumnGutter=\"\(f(HouseStyle.gutter))\" Top=\"\(f(page.isFront ? HouseStyle.Front.leadTop : HouseStyle.insideTop))\" "
            + "Bottom=\"\(f(HouseStyle.page.height - HouseStyle.bottom))\" Left=\"\(f(HouseStyle.margin))\" Right=\"\(f(HouseStyle.margin))\" ColumnDirection=\"Horizontal\" ColumnsPositions=\"\(positions.joined(separator: " "))\" />\n"
            + "\t\t</Page>\n"
        for item in under + text + over { x += "\t\t" + item + "\n" }
        x += "\t</Spread>\n</idPkg:Spread>\n"
        spreads.append((spreadID, pageID, x))
    }

    private func caption(_ t: NSAttributedString, in tr: CGRect) -> String {
        let r = tr.insetBy(dx: 0, dy: -2)
        var runs: [Run] = []
        t.enumerateAttributes(in: NSRange(location: 0, length: t.length), options: []) { a, range, _ in
            let name = (a[.font] as? NSFont)?.fontName ?? ""
            let style = a[Markup.italicKey] as? Bool == true ? faceStyle(a)
                : name.contains("Bold") ? "Bold" : (name.hasSuffix("-It") ? "Italic" : "Regular")
            runs.append(Run(text: (t.string as NSString).substring(with: range), fontStyle: style))
        }
        let sid = id()
        story(sid, [Para(style: "Caption", attrs: tr.width < 300 ? ["Justification": "LeftAlign"] : [:], runs: runs)])
        return textFrame(Frame(rect: r, story: sid, firstBaseline: firstBaseline(t, width: tr.width) + 2,
                               wrap: fitted(Wrap(mode: "BoundingBoxTextWrap", top: 0, left: HouseStyle.gutter, bottom: 8, right: HouseStyle.gutter), around: r)))
    }

    /// One line of type positioned by its baseline, as `Composer.label` draws it.
    /// Where `Composer.label` really puts a line's baseline: it frames the line from the font's ascender and lets
    /// TextKit place the baseline inside, a fraction of a point off the nominal one.
    private func drawnBaseline(_ text: String, face: String, size: CGFloat, baseline: CGFloat) -> CGFloat {
        let font = HouseStyle.font(face, size)
        guard !text.isEmpty else { return baseline }
        let s = NSAttributedString(string: text, attributes: [.font: font])
        let storage = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: 2000, height: 100)); tc.lineFragmentPadding = 0
        lm.addTextContainer(tc); lm.ensureLayout(for: tc)
        return baseline - font.ascender + lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + lm.location(forGlyphAt: 0).y
    }

    private func label(_ text: String, style: String, baseline nominal: CGFloat, align: Composer.Align, width: CGFloat = 400, fontStyle: String? = nil,
                       face: String? = nil, size: CGFloat = 12, attrs: [String: String] = [:]) -> String {
        let face = face ?? ["Folio": "Raleway-Bold", "Jump Line": "Raleway-Bold"][style] ?? "Raleway-SemiBold"
        let baseline = drawnBaseline(text, face: face, size: size, baseline: nominal)
        let x: CGFloat, just: String
        switch align {
        case .left(let l): x = l; just = "LeftAlign"
        case .center(let c): x = c - width / 2; just = "CenterAlign"
        case .right(let r): x = r - width; just = "RightAlign"
        }
        let sid = simpleStory(style, text, attrs: (just == "LeftAlign" ? [:] : ["Justification": just]).merging(attrs) { _, new in new }, fontStyle: fontStyle)
        let rise = max(14, (size * 1.17).rounded(.up))           // 14 and 20 at the house 12 pt, as before
        return textFrame(Frame(rect: CGRect(x: x, y: baseline - rise, width: width, height: rise + max(6, size / 2)), story: sid, firstBaseline: rise))
    }

    // MARK: placed components

    /// The swatch nearest a component's colour: the paper's red, paper white, or black. The template's swatches
    /// are all a component can use until the component editor (phase 6) brings colours of its own.
    private func swatch(_ p: Paint) -> String {
        let red = Paint.red
        if abs(p.r - red.r) < 0.03, abs(p.g - red.g) < 0.03, abs(p.b - red.b) < 0.03 { return "Color/C=15 M=100 Y=100 K=0" }
        return 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b > 0.5 ? "Color/Paper" : "Color/Black"
    }

    /// A text colour as an override, only where it differs from what the paragraph style already gives.
    private func colorAttr(_ p: Paint?, styleIsPaper: Bool) -> [String: String] {
        let s = swatch(p ?? .ink)
        if s == "Color/Paper" { return styleIsPaper ? [:] : ["FillColor": s] }
        if s == "Color/Black" { return styleIsPaper ? ["FillColor": "Color/C=0 M=0 Y=0 K=100"] : [:] }
        return ["FillColor": s]
    }

    /// The font style InDesign names for a face, telling Raleway's SemiBold from its Bold.
    private func faceStyle(_ font: NSFont?) -> String? {
        (font?.fontName ?? "").contains("SemiBold") ? "SemiBold" : fontStyle(font)
    }

    /// A field run's InDesign style: an *italic* run (Composer.marked) names its face exactly, Raleway's real
    /// italic for the slant Typeset draws; any other run as before.
    private func faceStyle(_ attrs: [NSAttributedString.Key: Any]) -> String? {
        let font = attrs[.font] as? NSFont
        guard attrs[Markup.italicKey] as? Bool == true, let n = font?.fontName else { return faceStyle(font) }
        let named = ["MinionPro-Regular": "Regular", "MinionPro-It": "Italic", "MinionPro-Bold": "Bold", "MinionPro-BoldIt": "Bold Italic",
                     "UtopiaStd-SemiboldSubh": "Semibold Subhead", "UtopiaStd-BoldIt": "Bold Italic",
                     "MyriadPro-Regular": "Regular", "MyriadPro-It": "Italic",
                     "Raleway": "Italic", "Raleway-Regular": "Italic", "Raleway-Medium": "Medium Italic",
                     "Raleway-SemiBold": "SemiBold Italic", "Raleway-Bold": "Bold Italic"]
        return named[n] ?? "Italic"
    }

    /// A field's runs, face by face (its *italic* included), one paragraph per line.
    private func fieldParas(_ t: NSAttributedString, style: String, attrs: [String: String] = [:], leading: CGFloat? = nil,
                            uppercase: Bool = false, tracking: CGFloat = 0) -> [Para] {
        var paras: [Para] = []
        let ns = t.string as NSString
        for (k, r) in Composer.paragraphRanges(t.string).enumerated() {
            guard r.length > 0 || k == 0 else { continue }
            var runs: [Run] = []
            t.enumerateAttributes(in: r, options: []) { a, range, _ in
                let s = ns.substring(with: range)
                runs.append(Run(text: uppercase ? s.uppercased() : s, fontStyle: faceStyle(a), tracking: tracking, leading: leading))
            }
            paras.append(Para(style: style, attrs: attrs, runs: runs))
        }
        return paras
    }

    /// A field as a story of its own; its id.
    private func fieldStory(_ t: NSAttributedString, style: String, attrs: [String: String] = [:], leading: CGFloat? = nil,
                            uppercase: Bool = false, tracking: CGFloat = 0) -> String {
        let sid = id()
        story(sid, fieldParas(t, style: style, attrs: attrs, leading: leading, uppercase: uppercase, tracking: tracking))
        return sid
    }

    private func justification(_ a: TextAlign?, _ fallback: String = "LeftAlign") -> [String: String] {
        switch a { case .left: ["Justification": "LeftAlign"]; case .center: ["Justification": "CenterAlign"]
        case .right: ["Justification": "RightAlign"]; case nil: ["Justification": fallback] }
    }

    private func ovalPath(_ w: CGFloat, _ h: CGFloat) -> String {
        let k: CGFloat = 0.5523, rx = w / 2, ry = h / 2
        func pt(_ x: CGFloat, _ y: CGFloat, _ lx: CGFloat, _ ly: CGFloat, _ rx2: CGFloat, _ ry2: CGFloat) -> String {
            "<PathPointType Anchor=\"\(f(x)) \(f(y))\" LeftDirection=\"\(f(lx)) \(f(ly))\" RightDirection=\"\(f(rx2)) \(f(ry2))\" />"
        }
        return "<Properties><PathGeometry><GeometryPathType PathOpen=\"false\"><PathPointArray>"
            + pt(0, ry, 0, ry + k * ry, 0, ry - k * ry)
            + pt(rx, 0, rx - k * rx, 0, rx + k * rx, 0)
            + pt(w, ry, w, ry - k * ry, w, ry + k * ry)
            + pt(rx, h, rx + k * rx, h, rx - k * rx, h)
            + "</PathPointArray></GeometryPathType></PathGeometry></Properties>"
    }

    private func shape(_ kind: String, _ r: CGRect, _ s: ShapeElement) -> String {
        let stroke = s.stroke.map { "StrokeWeight=\"\(f(s.strokeWidth))\" StrokeColor=\"\(swatch($0))\" StrokeAlignment=\"InsideAlignment\"" }
        let strokeAttrs = s.strokeWidth > 0 ? stroke ?? "StrokeWeight=\"0\" StrokeColor=\"Swatch/None\"" : "StrokeWeight=\"0\" StrokeColor=\"Swatch/None\""
        return "<\(kind) Self=\"\(id())\" ContentType=\"Unassigned\" StoryTitle=\"$ID/\" \(common) FillColor=\"\(s.fill.map(swatch) ?? "Swatch/None")\" \(strokeAttrs) "
            + "AppliedObjectStyle=\"ObjectStyle/$ID/[Normal Graphics Frame]\" ItemTransform=\"\(at(r))\">"
            + (kind == "Oval" ? ovalPath(r.width, r.height) : rectPath(r.width, r.height)) + wrapXML("None") + "</\(kind)>"
    }

    /// A component's embedded art, written out once so it can be placed (and embedded or linked) like a picture.
    private var artFiles: [ArtElement.ID: String] = [:]
    private func artFile(_ a: ArtElement) -> String? {
        if let p = artFiles[a.id] { return p }
        let isPDF = a.data.starts(with: Array("%PDF".utf8))
        var name = (a.name as NSString).lastPathComponent
        if name.isEmpty { name = "art" }
        let ext = (name as NSString).pathExtension.lowercased()
        if isPDF, ext != "pdf" { name = (name as NSString).deletingPathExtension + ".pdf" }
        else if !isPDF, ext.isEmpty { name += ".img" }                               // read by NSImage and converted on the way out
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Typeset-IDML-art").appendingPathComponent(a.id.uuidString)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try a.data.write(to: url, options: .atomic)
        } catch { return nil }
        artFiles[a.id] = url.path
        return url.path
    }

    /// A short piece of display type in a box, set from its top as the composer sets it: its runs keep their faces.
    private func displayText(_ t: NSAttributedString, style: String, attrs: [String: String], in r: CGRect, leading: CGFloat? = nil,
                             inset: CGFloat = 0, stroke: CGFloat = 0, uppercase: Bool = false, tracking: CGFloat = 0) -> String {
        // its faces run by run (an italic title in a headline, a bold credit in a caption, *italic* in any field)
        let sid = id()
        story(sid, fieldParas(t, style: style, attrs: attrs, leading: leading, uppercase: uppercase, tracking: tracking))
        return textFrame(Frame(rect: r, story: sid, firstBaseline: firstBaseline(t, width: max(1, r.width - 2 * inset)) + inset, inset: inset, stroke: stroke))
    }

    /// Writes each placed component on the page element by element, in the order the composer draws them: its
    /// shapes, lines, preset text and art, and its frames as filled (issue fields for this page, teaser headlines
    /// set as a group, pictures with their crop). Body and whole-story frames aren't written yet: they need
    /// threading into their stories (repro/notes/parked-bugs.md (kept locally, not in git)).
    private func components(_ page: PageLayout, number: Int, section: String, firstPage: [Article.ID: Int], into group: inout [String]) {
        for p in page.components {
            guard let rc = ResolvedComponent(p, in: issue, pageColumns: layout.columns) else { continue }
            let teasers = rc.version.frames.contains { $0.type == .teaserHeadline } ? composer.teaserSetting(of: rc, articles: articles) : nil
            var out: [String] = []                   // the component's items, written as one group
            defer { if !out.isEmpty { group.append(groupXML(out, name: componentName(p))) } }
            for e in rc.version.elements {
                switch e {
                case .line(let l):
                    out.append(line(from: rc.point(l.from), to: rc.point(l.to), weight: l.width, color: swatch(l.color)))
                case .rect(let s):
                    out.append(shape("Rectangle", rc.rect(s.box), s))
                case .ellipse(let s):
                    out.append(shape("Oval", rc.rect(s.box), s))
                case .text(let t):
                    let r = rc.rect(t.box)
                    let font = HouseStyle.font(t.face, t.size)
                    var attrs = justification(t.alignment).merging(colorAttr(t.color, styleIsPaper: false)) { _, new in new }
                    if t.size != 12 { attrs["PointSize"] = f(t.size) }
                    let sid = simpleStory("Folio", t.text, attrs: attrs, fontStyle: faceStyle(font) ?? "Regular")
                    out.append(textFrame(Frame(rect: r, story: sid, firstBaseline: firstBaseline(t.attributed, width: r.width))))
                case .art(let a):
                    if let path = artFile(a) { out.append(picture(rc.rect(a.box), path: path, stroke: 0, fill: false, wrap: nil, stretch: true)) }
                case .frame(let cf):
                    if let x = componentFrame(cf, of: rc, number: number, section: section, firstPage: firstPage, teasers: teasers) { out.append(x) }
                }
            }
        }
    }

    /// A placed component's items as one InDesign group, named as its selection box reads ("Header v1"), so it
    /// moves as one piece. The items keep their page coordinates: the group adds no transform of its own.
    private func groupXML(_ items: [String], name: String) -> String {
        "<Group Self=\"\(id())\" ItemTransform=\"1 0 0 1 0 0\" Visible=\"true\" Name=\"\(xmlEscape(name))\" ItemLayer=\"ucc\" Locked=\"false\" LocalDisplaySetting=\"Default\">"
            + items.joined() + "</Group>"
    }

    private func componentName(_ p: PlacedComponent) -> String {
        let n = issue.componentName(p.component) ?? "Component"
        return p.custom != nil ? "\(n) custom" : "\(n) v\(p.version)"
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func componentFrame(_ cf: ComponentFrame, of rc: ResolvedComponent, number: Int, section: String,
                                firstPage: [Article.ID: Int], teasers: Composer.TeaserSetting?) -> String? {
        let r = rc.rect(cf.box)
        let fill = rc.placed.fill(for: cf)
        let article = fill?.article.flatMap { articles[$0] }
        let photo = article.flatMap { a in a.photos.first { $0.id == fill?.photo } ?? a.photos.first }
        /// One line of type on the frame's first baseline, as the composer's issue fields are drawn.
        func field(_ text: String, style: String, styleIsPaper: Bool) -> String {
            let face = cf.face ?? ComponentFrame.fieldFace, size = cf.size ?? 12
            let align: Composer.Align
            switch cf.alignment ?? .left { case .left: align = .left(r.minX); case .center: align = .center(r.midX); case .right: align = .right(r.maxX) }
            var attrs = justification(cf.alignment).merging(colorAttr(cf.color, styleIsPaper: styleIsPaper)) { _, new in new }
            if size != 12 { attrs["PointSize"] = f(size) }
            return label(text, style: style, baseline: r.minY + HouseStyle.font(face, size).ascender, align: align, width: r.width,
                         fontStyle: faceStyle(HouseStyle.font(face, size)), face: face, size: size, attrs: attrs)
        }
        func color(_ paper: Bool = false) -> [String: String] { cf.color.map { colorAttr($0, styleIsPaper: paper) } ?? [:] }
        switch cf.type {
        case .pageNumber, .volume, .edition, .desk, .date:
            let text = Composer.fieldText(cf, issue: issue, number: number, section: section)
            guard !text.isEmpty else { return nil }
            // the dateline's face and white on the bar are the Dateline style's; the folio's bold black the Folio's
            let dateline = (cf.face ?? ComponentFrame.fieldFace) == "Raleway-SemiBold"
            return field(text, style: dateline ? "Dateline" : "Folio", styleIsPaper: dateline)
        case .teaserPage:
            guard let a = article else { return nil }
            return field(firstPage[a.id].map { "Page \($0)" } ?? "Inside", style: "Teaser Page", styleIsPaper: true)
        case .teaserHeadline:
            guard let a = article, let t = teasers else { return nil }
            let attrs = ["PointSize": f(t.size)].merging(cf.alignment.map { justification($0) } ?? [:]) { _, new in new }.merging(color()) { _, new in new }
            let sid = fieldStory(Composer.teaser(a.teaserHeadline, size: t.size, lineHeight: t.lineHeight), style: "Teaser", attrs: attrs, leading: t.size * t.lineHeight)
            return textFrame(Frame(rect: CGRect(x: r.minX, y: r.minY + t.drop, width: r.width, height: t.height), story: sid,
                                   firstBaseline: firstBaseline(Composer.teaser(a.teaserHeadline, size: t.size, lineHeight: t.lineHeight), width: r.width)))
        case .image:
            if let e = fill?.extra.flatMap({ extras[$0] }) {        // an ad or graphic in an image frame crops like a photo
                return picture(r, path: e.path, stroke: HouseStyle.photoOutline, fill: true, wrap: nil, focus: fill?.focus ?? CGPoint(x: 0.5, y: 0.5))
            }
            guard let ph = photo else { return nil }
            return picture(r, path: ph.path, stroke: HouseStyle.photoOutline, fill: true, wrap: nil, focus: fill?.focus ?? CGPoint(x: 0.5, y: 0.5))
        case .ad:
            guard let e = fill?.extra.flatMap({ extras[$0] }) else { return nil }
            return picture(Composer.fitted(composer.image(e.path)?.size, in: r), path: e.path, stroke: HouseStyle.photoOutline, fill: false, wrap: nil)
        case .headline:
            guard let a = article, !a.plainHeadline.trimmed.isEmpty else { return nil }
            let size = cf.size ?? HouseStyle.headlineSize(columns: rc.columnsSpanned(by: cf.box))
            let attrs = ["PointSize": f(size)].merging(cf.alignment.map { justification($0) } ?? [:]) { _, new in new }.merging(color()) { _, new in new }
            let sid = id()
            story(sid, [Para(style: "Headline", attrs: attrs, runs: headlineRuns(a.headline.trimmed, size: size))])
            return textFrame(Frame(rect: r, story: sid, firstBaseline: firstBaseline(Composer.headline(markup: a.headline.trimmed, size: size), width: r.width)))
        case .kicker:
            guard let a = article, !a.kicker.trimmed.isEmpty else { return nil }
            return displayText(Composer.kicker(a.kicker.trimmed), style: "Folio", attrs: ["PointSize": f(HouseStyle.kickerSize)].merging(justification(cf.alignment)) { _, new in new }.merging(color()) { _, new in new },
                               in: r, leading: 12, uppercase: true, tracking: 120)
        case .author:
            guard let a = article, !a.author.trimmed.isEmpty else { return nil }
            let lines = Composer.bylineLines(a.author.trimmed, width: r.width).joined(separator: "\n")
            let s = Composer.marked(lines, [.font: HouseStyle.font("Raleway-SemiBold", cf.size ?? 12)])
            var attrs = justification(cf.alignment).merging(color()) { _, new in new }
            if let z = cf.size { attrs["PointSize"] = f(z) }
            return displayText(s, style: "Byline", attrs: attrs, in: r, leading: HouseStyle.bylineLeading)
        case .authorTitle:
            guard let a = article, !a.authorTitle.trimmed.isEmpty else { return nil }
            let s = Composer.marked(a.authorTitle.trimmed, [.font: HouseStyle.font("MyriadPro-It", cf.size ?? 10)])
            var attrs = justification(cf.alignment).merging(color()) { _, new in new }
            if let z = cf.size { attrs["PointSize"] = f(z) }
            return displayText(s, style: "Byline Title", attrs: attrs, in: r)
        case .caption, .credit:
            guard let ph = photo, let c = Composer.caption(cf.type == .caption ? ph : Photo(path: "", caption: "", credit: ph.credit), width: r.width) else { return nil }
            return displayText(c, style: "Caption", attrs: justification(cf.alignment).merging(color()) { _, new in new }, in: r)
        case .pullQuote:
            guard let a = article, !a.pullQuote.trimmed.isEmpty else { return nil }
            let t = Composer.pullQuote(a.pullQuote.trimmed, width: r.width)
            let size = (t.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 17
            return displayText(t, style: "Pull Quote", attrs: ["PointSize": f(size)].merging(cf.alignment.map { justification($0) } ?? [:]) { _, new in new }.merging(color()) { _, new in new },
                               in: r, leading: size * 1.2, inset: 10, stroke: HouseStyle.pullQuoteRule)
        case .body, .wholeStory:
            return nil                                               // not yet: see repro/notes/parked-bugs.md (kept locally, not in git)
        }
    }

    // MARK: the package

    func package() throws -> URL {
        let fm = FileManager.default
        let dir = packageURL.deletingPathExtension().appendingPathExtension("idml-package")
        try? fm.removeItem(at: dir)
        for sub in ["META-INF", "Resources", "MasterSpreads", "Spreads", "Stories", "XML"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        func put(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try put("mimetype", try IDMLExport.template("mimetype"))
        try put("META-INF/container.xml", try IDMLExport.template("container.xml"))
        for n in ["Styles", "Graphic", "Fonts", "Preferences"] { try put("Resources/\(n).xml", try IDMLExport.template("\(n).xml")) }
        try put("MasterSpreads/MasterSpread_ud6.xml", try IDMLExport.template("MasterSpread_ud6.xml"))
        try put("XML/Tags.xml", try IDMLExport.template("Tags.xml"))
        try put("XML/BackingStory.xml", try IDMLExport.template("BackingStory.xml"))
        for s in spreads { try put("Spreads/Spread_\(s.id).xml", s.xml) }
        for s in stories { try put("Stories/Story_\(s.id).xml", s.xml) }

        var map = try IDMLExport.template("designmap.xml")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        map = map.replacingOccurrences(of: "@@NAME@@", with: esc(packageURL.deletingPathExtension().lastPathComponent + ".indd"))
        map = map.replacingOccurrences(of: "@@STORYLIST@@", with: (stories.map(\.id) + ["ub1"]).joined(separator: " "))
        map = map.replacingOccurrences(of: "@@SPREADS@@", with: (["<idPkg:MasterSpread src=\"MasterSpreads/MasterSpread_ud6.xml\" />"]
            + spreads.map { "<idPkg:Spread src=\"Spreads/Spread_\($0.id).xml\" />" }).joined(separator: "\n\t"))
        map = map.replacingOccurrences(of: "@@SECTIONS@@", with: "<Section Self=\"\(id())\" Length=\"\(spreads.count)\" Name=\"\" ContinueNumbering=\"true\" IncludeSectionPrefix=\"false\" Marker=\"\" "
            + "PageStart=\"\(spreads.first?.pageID ?? "n")\" SectionPrefix=\"\"><Properties><PageNumberStyle type=\"enumeration\">Arabic</PageNumberStyle></Properties></Section>")
        map = map.replacingOccurrences(of: "@@STORIES@@", with: (["<idPkg:BackingStory src=\"XML/BackingStory.xml\" />"]
            + stories.map { "<idPkg:Story src=\"Stories/Story_\($0.id).xml\" />" }).joined(separator: "\n\t"))
        try put("designmap.xml", map)

        // linked pictures, beside the package where InDesign's links point
        if !embed, !links.isEmpty {
            try fm.createDirectory(at: linksDir, withIntermediateDirectories: true)
            for l in links.values {
                let dest = linksDir.appendingPathComponent(l.name)
                try? fm.removeItem(at: dest)
                if l.converted, let data = l.data { try data.write(to: dest) } else { try fm.copyItem(at: l.url, to: dest) }
            }
        }

        // zip: the mimetype first and stored, as the format requires; everything else deflated
        try? fm.removeItem(at: packageURL)
        try fm.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        func zip(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = args
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw IDMLExport.Failure.zip(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "status \(p.terminationStatus)")
            }
        }
        try zip(["-X", "-0", "-q", packageURL.path, "mimetype"])
        try zip(["-X", "-r", "-q", "-D", packageURL.path, "META-INF", "designmap.xml", "Resources", "MasterSpreads", "Spreads", "Stories", "XML"])
        try? fm.removeItem(at: dir)
        return packageURL
    }
}
