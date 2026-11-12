import Foundation

/// The paper's desks. Raw values match the section names used by the layout engine.
enum Desk: String, Codable, CaseIterable, Identifiable {
    case news = "News"
    case sports = "Sports"
    case opinion = "Editorial/Opinion"
    case features = "Features"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .news: "newspaper"
        case .sports: "sportscourt"
        case .opinion: "quote.bubble"
        case .features: "sparkles"
        }
    }
}

/// A photo or illustration attached to a story. The first photo in a story is its lead.
struct Photo: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var caption = ""
    var credit = ""

    init(path: String, caption: String = "", credit: String = "") {
        self.path = path; self.caption = caption; self.credit = credit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        credit = try c.decodeIfPresent(String.self, forKey: .credit) ?? ""
    }
}

/// One story as it comes in from a writer. Body paragraphs use light markup: *italic*, **bold**.
struct Article: Codable, Identifiable, Hashable {
    var id = UUID()
    var desk: Desk = .news
    var headline = ""
    /// The small label over the headline ("Women's Hockey", "News Analysis"); most stories have none.
    var kicker = ""
    /// A shorter headline for the teaser over the nameplate, when the real one is too long for it; empty means the headline.
    var teaser = ""
    /// The teaser as markup (*italic* kept): its own, or the headline's.
    var teaserHeadline: String { teaser.trimmingCharacters(in: .whitespaces).isEmpty ? headline.trimmingCharacters(in: .whitespaces) : teaser.trimmingCharacters(in: .whitespaces) }
    var author = ""
    var authorTitle = ""
    var body: [String] = []
    var pullQuote = ""
    /// The word in "See ___, Page N." when the story jumps; empty means the one picked from the headline.
    var jump = ""
    /// The jump word as set: the story's own, or the headline's.
    var jumpWord: String { jump.trimmed.isEmpty ? HouseStyle.jumpWord(headline) : jump.trimmed.uppercased() }
    var photos: [Photo] = []
    /// The story's page on poly.rpi.edu, once it has been read from or matched to the website.
    var source = ""
    var updated = Date()

    var plainHeadline: String { Markup.plain(headline) }

    var bodyText: String { body.joined(separator: "\n") }

    var wordCount: Int {
        bodyText.split(whereSeparator: { $0.isWhitespace }).count
    }

    enum CodingKeys: String, CodingKey {
        case id, desk, headline, kicker, teaser, author, authorTitle, body, pullQuote, jump, photos, source, updated
        case photo, caption, credit          // single-photo format from earlier versions (read only)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        desk = c.value(.desk, or: .news)              // a desk this build doesn't know reads as News
        headline = c.value(.headline, or: "")
        kicker = c.value(.kicker, or: "")
        teaser = c.value(.teaser, or: "")
        author = c.value(.author, or: "")
        authorTitle = c.value(.authorTitle, or: "")
        body = c.value(.body, or: [String]())
        pullQuote = c.value(.pullQuote, or: "")
        jump = c.value(.jump, or: "")
        photos = c.lossy(.photos)
        if photos.isEmpty, let legacy = c.value(.photo, or: nil as String?) {
            photos = [Photo(path: legacy, caption: c.value(.caption, or: ""), credit: c.value(.credit, or: ""))]
        }
        source = c.value(.source, or: "")
        updated = c.value(.updated, or: Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(desk, forKey: .desk)
        try c.encode(headline, forKey: .headline); try c.encode(kicker, forKey: .kicker); try c.encode(teaser, forKey: .teaser)
        try c.encode(author, forKey: .author); try c.encode(authorTitle, forKey: .authorTitle)
        try c.encode(body, forKey: .body); try c.encode(pullQuote, forKey: .pullQuote); try c.encode(jump, forKey: .jump)
        try c.encode(photos, forKey: .photos); try c.encode(source, forKey: .source)
        try c.encode(updated, forKey: .updated)
    }
}

/// An ad, standalone image or graphic that runs in the paper on its own, not as part of a story.
struct Extra: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case ad = "Ad", image = "Image", graphic = "Graphic"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .ad: "megaphone"; case .image: "photo"; case .graphic: "chart.bar.doc.horizontal" }
        }
    }
    var id = UUID()
    var kind: Kind = .ad
    var title = ""
    var path: String                  // image or PDF file
    var columns = 2                   // the width it should run at
    var height: CGFloat?              // points; nil keeps the file's proportions
    var caption = ""
    var credit = ""
    var updated = Date()

    init(kind: Kind, path: String, title: String = "") {
        self.kind = kind; self.path = path; self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .ad
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decode(String.self, forKey: .path)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 2
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        credit = try c.decodeIfPresent(String.self, forKey: .credit) ?? ""
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }
}

struct Issue: Codable {
    var publication = Paper.publicationName
    var volume = "I"
    var edition = "1"
    var date = Date()
    /// Stories in priority order: the first leads the front page.
    var articles: [Article] = []
    var extras: [Extra] = []
    var stage: Stage = .stories
    var layout: IssueLayout?
    /// A copy of every component version the pages use (Components.swift), so the file stands alone.
    var componentVersions: [Component] = []
    /// The file format this issue was saved in. 1: before the Header and Folio were components the pages carry
    /// (the app drew them itself); 2: since; 3: since components can repeat on new pages (templates). A file without
    /// the key is 1, and `migrateComponents` brings it up.
    var format = Issue.currentFormat
    static let currentFormat = 3
    /// The template the issue was made from (Templates.swift): what the generator, Clear Pages and Add Page put on
    /// its pages. Nil for an issue made before templates, which gets The Polytechnic's.
    var template: IssueTemplate?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publication = try c.decodeIfPresent(String.self, forKey: .publication) ?? publication
        volume = try c.decodeIfPresent(String.self, forKey: .volume) ?? volume
        edition = try c.decodeIfPresent(String.self, forKey: .edition) ?? edition
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? date
        articles = c.lossy(.articles)                  // one unreadable story or ad is dropped, not the issue
        extras = c.lossy(.extras)
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .stories
        layout = c.value(.layout, or: nil as IssueLayout?)
        componentVersions = c.lossy(.componentVersions)
        format = c.value(.format, or: 1)
        template = c.value(.template, or: nil as IssueTemplate?)
    }
}

extension Issue: Equatable {}

struct StaffMember: Codable, Hashable, Identifiable {
    var name: String
    var role: String
    var id: String { name + "|" + role }
}
