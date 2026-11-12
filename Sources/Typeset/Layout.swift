import Foundation
import CoreGraphics

/// Where the editor is in making the issue.
enum Stage: String, Codable, CaseIterable, Identifiable {
    case stories, priority, pages
    var id: String { rawValue }
    var title: String {
        switch self { case .stories: "Content"; case .priority: "Priority"; case .pages: "Pages" }
    }
}

/// A rectangle in page points (top-left origin), stored plainly so layouts hash and compare cheaply.
struct Box: Codable, Hashable {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    init(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, w: r.width, h: r.height) }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// A generated paper: pages of story blocks and pictures, in page order.
struct IssueLayout: Codable, Hashable {
    var pages: [PageLayout] = []
    var columns = 3
    var charsPerLine = 0.0
    var basis: [Article.ID] = []        // the ranked story order this was generated from
    var seed: UInt64 = 0
    var grid: Grid { Grid(columns: columns) }
}

struct PageLayout: Codable, Hashable, Identifiable {
    var id = UUID()
    var isFront = false
    var stories: [StoryBlock] = []
    var insets: [Inset] = []
    var components: [PlacedComponent] = []   // placed components (Components.swift); stories wrap around them
    /// Read from a file saved before the Header was a component (the stories teased above the nameplate and the
    /// teaser photo), kept only until `Issue.migrateComponents` fills the Header with them; never written back.
    var legacyTeasers: [Article.ID] = []
    var legacyTeaserPhoto: LegacyTeaserPhoto?

    private enum CodingKeys: String, CodingKey { case id, isFront, stories, insets, teasers, components }

    /// Blocks as a reader meets them: down the page, left to right. A story that appears twice continues in this order.
    var readingOrder: [StoryBlock] { Self.readingOrder(stories) }
    static func readingOrder(_ blocks: [StoryBlock]) -> [StoryBlock] {
        blocks.sorted {
            abs($0.frame.y - $1.frame.y) > 6 ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
        }
    }
}

// Saved layouts decode leniently: a key a newer build added falls back to its default, and a page, block or
// picture that can't be read is dropped on its own instead of taking the whole layout with it.

/// An array that decodes what it can and skips elements that fail.
struct Lossy<Element: Decodable>: Decodable {
    var items: [Element]
    private struct Skip: Decodable {}
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let v = try? c.decode(Element.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
}

extension KeyedDecodingContainer {
    /// A value, or `fallback` when it's missing or unreadable.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
    /// An array, keeping the elements that decode.
    func lossy<T: Decodable>(_ key: Key) -> [T] { ((try? decodeIfPresent(Lossy<T>.self, forKey: key)) ?? nil)?.items ?? [] }
}

extension IssueLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        pages = c.lossy(.pages)
        columns = c.value(.columns, or: 3)
        charsPerLine = c.value(.charsPerLine, or: 0.0)
        basis = c.lossy(.basis)
        seed = c.value(.seed, or: UInt64(0))
    }
}

extension PageLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.value(.id, or: UUID())
        isFront = c.value(.isFront, or: false)
        stories = c.lossy(.stories)
        insets = c.lossy(.insets)
        components = c.lossy(.components)
        legacyTeasers = c.lossy(.teasers)
        legacyTeaserPhoto = (c.lossy(.insets) as [LegacyTeaserPhoto]).first
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(isFront, forKey: .isFront)
        try c.encode(stories, forKey: .stories); try c.encode(insets, forKey: .insets); try c.encode(components, forKey: .components)
    }
}

/// The front page's teaser photo as files before components kept it: an inset of kind "teaser", which is no
/// longer a kind of inset. Decodes only that; anything else throws, so it's skipped.
struct LegacyTeaserPhoto: Hashable, Decodable {
    var article: Article.ID
    var photo: Photo.ID
    var focusX: CGFloat = 0.5
    var focusY: CGFloat = 0.5
    private enum CodingKeys: String, CodingKey { case kind, article, photo, focusX, focusY }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .kind) == "teaser" else { throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "not a teaser") }
        article = try c.decode(Article.ID.self, forKey: .article)
        photo = try c.decode(Photo.ID.self, forKey: .photo)
        focusX = c.value(.focusX, or: 0.5).clamped(0, 1); focusY = c.value(.focusY, or: 0.5).clamped(0, 1)
    }
}

extension StoryBlock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let columns = max(1, c.value(.columns, or: 1))
        // a block needs its story and its frame; the rest has defaults
        self.init(id: c.value(.id, or: UUID()), article: try c.decode(Article.ID.self, forKey: .article),
                  frame: try c.decode(Box.self, forKey: .frame), columns: columns,
                  headlineSize: c.value(.headlineSize, or: HouseStyle.headlineSize(columns: columns)),
                  bylineColumns: max(1, min(columns, c.value(.bylineColumns, or: 1))))
    }
}

extension Inset {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, or: UUID()), kind: try c.decode(Kind.self, forKey: .kind),
                  article: c.value(.article, or: nil as Article.ID?), photo: c.value(.photo, or: nil as Photo.ID?),
                  extra: c.value(.extra, or: nil as Extra.ID?), frame: try c.decode(Box.self, forKey: .frame),
                  focusX: c.value(.focusX, or: 0.5).clamped(0, 1), focusY: c.value(.focusY, or: 0.5).clamped(0, 1))
    }
}

/// An alignment line shown while something is dragged.
struct Guide: Hashable {
    enum Axis { case x, y }
    var axis: Axis
    var at: CGFloat
}

/// What's selected on the page canvas.
enum LayoutSelection: Hashable {
    case block(StoryBlock.ID)
    case inset(Inset.ID)
    case component(PlacedComponent.ID)        // a placed component, taken whole (phase 5)
}

/// A story's module on a page: headline across the top, byline, then body in columns.
/// A story that runs over more than one block jumps ("See ROBOTICS, Page 7.") in page order.
struct StoryBlock: Codable, Hashable, Identifiable {
    var id = UUID()
    var article: Article.ID
    var frame: Box
    var columns: Int
    var headlineSize: CGFloat
    /// How many of the block's columns the byline spans; 1 is the house style, wider for a long shared byline.
    var bylineColumns = 1
}

/// Something placed on the page that text wraps around.
struct Inset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case photo, pullQuote, extra }
    var id = UUID()
    var kind: Kind
    var article: Article.ID?          // the story this belongs to; nil for an ad or graphic
    var photo: Photo.ID?
    var extra: Extra.ID?
    /// Photo: the picture (its caption hangs below). Pull quote: the box (its height follows the text).
    var frame: Box
    /// Which part of a picture shows when it's cropped to fill its frame: 0 keeps the left or top edge, 1 the
    /// right or bottom, 0.5 the middle. Only the axis with something to hide uses it.
    var focusX: CGFloat = 0.5
    var focusY: CGFloat = 0.5
    var focus: CGPoint {
        get { CGPoint(x: focusX, y: focusY) }
        set { focusX = newValue.x.clamped(0, 1); focusY = newValue.y.clamped(0, 1) }
    }
}
