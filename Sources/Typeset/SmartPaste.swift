import AppKit

/// Turns whatever a writer pastes (Google Docs, Word, Pages, plain email text) into clean paragraphs,
/// and recognises headline / byline / title at the top of a pasted story.
enum SmartPaste {
    static let titleWords = ["reporter", "editor", "marshal", "correspondent", "contributor", "columnist", "writer", "chief", "staff", "director", "coordinator"]

    /// Paragraphs from the pasteboard, keeping italics and bold as markup and dropping all other formatting.
    static func paragraphs(from pb: NSPasteboard = .general) -> [String] {
        var paras: [String] = []
        if let rtf = pb.data(forType: .rtf), let att = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            paras = Markup.paragraphs(from: att)
        } else if let html = pb.data(forType: .html),
                  let att = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                                    documentAttributes: nil) {
            paras = Markup.paragraphs(from: att)
        } else if let s = pb.string(forType: .string) {
            paras = plainParagraphs(s).map(Markup.escape)      // plain text has no markup: its asterisks are literal
        }
        return paras.map(clean).filter { !$0.isEmpty }
    }

    static func plainParagraphs(_ s: String) -> [String] {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Hard-wrapped text (email) breaks lines mid-paragraph and separates paragraphs with blank lines; text from
        // a doc puts each paragraph on one long line, whatever blank lines it also has. Tell them apart by line length.
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let long = lines.filter { $0.count > 100 }.count
        if text.contains("\n\n"), long * 2 < lines.count {
            return text.components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\n", with: " ") }
        }
        return text.components(separatedBy: "\n")
    }

    /// A new article from the pasteboard, or nil if there's no text on it. `desk` is used unless the paste names one.
    static func article(staff: [StaffMember], desk: Desk) -> Article? {
        article(from: paragraphs(), staff: staff, desk: desk)
    }

    static func article(from paras: [String], staff: [StaffMember], desk: Desk) -> Article? {
        guard !paras.isEmpty else { return nil }
        var a = labeledArticle(paras, desk: desk) ?? looseArticle(paras, staff: staff, desk: desk)
        if a.authorTitle.isEmpty, !a.author.isEmpty { a.authorTitle = defaultTitle(a.author, desk: a.desk, staff: staff) }
        return a
    }

    /// A story laid out the way a writer's submission form sends it: headline first, then byline, then body.
    private static func looseArticle(_ paras: [String], staff: [StaffMember], desk: Desk) -> Article {
        var rest = paras
        var a = Article()
        a.desk = desk
        a.headline = rest.removeFirst()
        for _ in 0..<3 {
            guard let first = rest.first else { break }
            let plain = Markup.plain(first).trimmingCharacters(in: .whitespaces)
            if let m = plain.range(of: #"^(?i)by\s+(.+)$"#, options: .regularExpression) {
                a.author = authors(String(plain[m]).replacingOccurrences(of: #"^(?i)by\s+"#, with: "", options: .regularExpression))
                rest.removeFirst(); continue
            }
            if let member = staff.first(where: { $0.name.caseInsensitiveCompare(plain) == .orderedSame }) {
                a.author = member.name
                rest.removeFirst(); continue
            }
            if !a.author.isEmpty, plain.split(separator: " ").count <= 5,
               titleWords.contains(where: { plain.lowercased().contains($0) }) {
                a.authorTitle = plain
                rest.removeFirst(); continue
            }
            break
        }
        a.body = rest
        return a
    }

    // MARK: labelled submissions ("Author: …", "Title: …", "Article: …")

    private enum Field { case headline, author, authorTitle, deskHint, pullQuote, body, unused }

    private static let fieldNames: [String: Field] = {
        var m: [String: Field] = [:]
        for k in ["title", "headline", "hed", "head", "story title", "article title", "headline title"] { m[k] = .headline }
        for k in ["author", "authors", "by", "byline", "writer", "writers", "reporter", "reporters", "written by", "name", "names"] { m[k] = .author }
        for k in ["author title", "authors title", "byline title", "position", "role", "staff title", "job title", "staff position"] { m[k] = .authorTitle }
        for k in ["kicker", "section", "desk", "category", "department", "topic", "beat", "tag", "tags"] { m[k] = .deskHint }
        for k in ["pull quote", "pullquote", "pull quotes"] { m[k] = .pullQuote }
        for k in ["article", "body", "text", "story", "content", "copy", "article text", "body text", "full text", "article body"] { m[k] = .body }
        for k in ["summary", "deck", "dek", "subhead", "subheadline", "subtitle", "excerpt", "description", "blurb", "teaser",
                  "photo", "photos", "image", "images", "caption", "captions", "photo caption", "credit", "photo credit",
                  "image credit", "date", "word count", "words", "email", "notes", "note to editor", "notes to editor",
                  "comments", "link", "links", "url", "slug", "keywords", "seo title", "meta description"] { m[k] = .unused }
        return m
    }()

    /// The field a paragraph opens, and what follows the label on its line.
    private static func field(_ para: String, inBody: Bool) -> (Field, String)? {
        let plain = Markup.plain(para)
        guard let colon = plain.firstIndex(of: ":") else { return nil }
        let label = plain[..<colon].lowercased()
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard let f = fieldNames[label] else { return nil }
        if inBody, f == .body { return nil }               // "Story: …" inside the copy is copy
        return (f, plain[plain.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// The article in a labelled submission, or nil if the paste isn't one. Fields the paper doesn't print
    /// (summary, kicker, photo notes) are dropped; a kicker or section only decides the desk.
    private static func labeledArticle(_ paras: [String], desk: Desk) -> Article? {
        let head = paras.prefix(while: { field($0, inBody: false)?.0 != .body })
        let labels = head.compactMap { field($0, inBody: false)?.0 }
        guard labels.count >= 2, labels.contains(.headline) || paras.count > head.count else { return nil }

        var values: [Field: [String]] = [:]
        var body: [String] = []
        var current: Field? = nil
        for p in paras {
            if let (f, value) = field(p, inBody: current == .body) {
                current = f
                if !value.isEmpty {
                    if f == .body { body.append(Markup.escape(value)) } else { values[f, default: []].append(Markup.escape(value)) }
                }
            } else if current == .body {
                body.append(p)
            } else if let f = current {
                values[f, default: []].append(p)
            }
        }

        var a = Article()
        let hints = (values[.deskHint] ?? []).map(Markup.plain).joined(separator: " ")
        a.desk = Self.desk(for: hints) ?? desk
        a.kicker = kicker(from: (values[.deskHint] ?? []).first.map(Markup.plain) ?? "")
        a.headline = values[.headline]?.joined(separator: " ") ?? ""
        a.author = authors(values[.author].map { Markup.plain($0.joined(separator: ", ")) } ?? "")
        a.authorTitle = values[.authorTitle].map { Markup.plain($0.joined(separator: " ")) } ?? ""
        a.pullQuote = values[.pullQuote]?.joined(separator: " ") ?? ""
        a.body = body
        if a.headline.isEmpty, !a.body.isEmpty { a.headline = a.body.removeFirst() }
        return a
    }

    /// A kicker worth printing: the label as given, unless it only names the desk ("Sports", "Opinion").
    static func kicker(from hint: String) -> String {
        let k = clean(hint)
        let bare = k.lowercased().replacingOccurrences(of: #"[^a-z/ ]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let desks = ["news", "sports", "sport", "opinion", "opinions", "editorial", "editorial/opinion", "features", "feature", ""]
        return desks.contains(bare) ? "" : k
    }

    /// The desk a kicker or section line points to, if it points anywhere.
    static func desk(for hint: String) -> Desk? {
        let h = " " + hint.lowercased().replacingOccurrences(of: #"[^a-z]+"#, with: " ", options: .regularExpression) + " "
        func has(_ words: [String]) -> Bool { words.contains { h.contains(" " + $0 + " ") } }
        if h.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if has(["opinion", "opinions", "editorial", "editorials", "op ed", "oped", "letter", "letters", "letter to the editor",
                "column", "columns", "commentary", "viewpoint", "perspective", "point counterpoint"]) { return .opinion }
        if has(["sport", "sports", "athletics", "hockey", "football", "basketball", "soccer", "lacrosse", "baseball", "softball",
                "volleyball", "swimming", "diving", "track", "field", "cross country", "tennis", "golf", "wrestling", "rowing",
                "crew", "fencing", "esports", "rugby", "ultimate", "intramurals", "club sports"]) { return .sports }
        if has(["feature", "features", "arts", "entertainment", "culture", "review", "reviews", "profile", "lifestyle",
                "food", "music", "film", "movies", "games", "gaming", "books", "theater", "theatre", "fun", "puzzles",
                "comics", "humor"]) { return .features }
        if has(["news", "campus", "local", "world", "national", "student government", "senate", "union"]) { return .news }
        return nil
    }

    /// "Marcus Delgado, Ava Brook" → "Marcus Delgado and Ava Brook"; three or more get commas and a final "and".
    static func authors(_ s: String) -> String {
        let names = s.replacingOccurrences(of: #"^(?i)\s*by\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(and|&)\s+|\s*[;/&]\s*"#, with: ",", options: .regularExpression)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// The title under a byline nobody gave one: a staff member's own title, otherwise Senior Reporter
    /// (Senior Reporters for a shared byline). Opinion pieces only take a staff title; others run without one.
    static func defaultTitle(_ author: String, desk: Desk, staff: [StaffMember]) -> String {
        if let member = staff.first(where: { $0.name.caseInsensitiveCompare(author) == .orderedSame }) {
            return Theme.bylineTitle(for: member.role)
        }
        if desk == .opinion { return "" }
        return author.contains(" and ") ? "Senior Reporters" : "Senior Reporter"
    }

    /// Typographic clean-up: curly quotes, em dashes, single spaces, no leading tabs.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "--", with: "—")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)
        return curlyQuotes(t)
    }

    static func curlyQuotes(_ s: String) -> String {
        var out = ""
        var prev: Character? = nil
        let openers: Set<Character> = [" ", "(", "[", "{", "—", "–", "-", "/", "*", "\u{2018}", "\u{201C}"]
        for ch in s {
            switch ch {
            case "\"": out.append(prev == nil || openers.contains(prev!) ? "\u{201C}" : "\u{201D}")
            case "'": out.append(prev == nil || openers.contains(prev!) ? "\u{2018}" : "\u{2019}")
            default: out.append(ch)
            }
            prev = ch
        }
        return out
    }
}
