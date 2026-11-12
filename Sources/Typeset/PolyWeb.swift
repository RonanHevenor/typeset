import AppKit

/// Reads stories from poly.rpi.edu. The site's article API gives the copy, the section and the pictures with their
/// captions; the story's page gives what the API keeps private: the byline titles and the photo credits.
enum PolyWeb {
    static let site = URL(string: "https://poly.rpi.edu")!
    /// Reading from the website is The Polytechnic's alone (its site's API): offered when setup names that site.
    static var enabled: Bool { let h = Paper.host.lowercased(); return h == "poly.rpi.edu" || h.hasSuffix(".poly.rpi.edu") }

    enum Failure: LocalizedError {
        case notThePoly, notFound(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notThePoly: "That isn't a link to a story on poly.rpi.edu."
            case .notFound(let what): "\(what) isn't on poly.rpi.edu."
            case .unreadable(let what): "poly.rpi.edu sent something Typeset couldn't read for \(what)."
            }
        }
    }

    /// A picture on the website, not downloaded yet.
    struct WebPhoto: Sendable {
        var url: URL
        var filename: String
        var caption: String
        var credit: String
    }

    /// One story as the website has it.
    struct Story: Sendable {
        var page: URL
        var desk: Desk
        var headline: String
        var kicker: String
        var author: String
        var authorTitle: String
        var body: [String]
        var photos: [WebPhoto]
    }

    /// The slug in a story link: https://poly.rpi.edu/news/2026/10/<slug>.
    static func slug(in link: String) -> String? {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = u.host?.lowercased(), host == "poly.rpi.edu" || host.hasSuffix(".poly.rpi.edu") else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let last = parts.last, !last.isEmpty else { return nil }
        return last
    }

    /// The slug of the story on the website with this headline, if there is exactly one that fits.
    static func slug(forHeadline headline: String) async throws -> String? {
        let wanted = normalized(headline)
        guard !wanted.isEmpty else { return nil }
        for op in ["equals", "like"] {
            let docs = try await articles(where: "plainTitle", op, Markup.plain(headline), limit: 5)
            if let exact = docs.first(where: { normalized($0["plainTitle"] as? String ?? "") == wanted }) {
                return exact["slug"] as? String
            }
            if op == "like", docs.count == 1 { return docs[0]["slug"] as? String }
        }
        return nil
    }

    /// The story with this slug, read from the API and its page.
    static func story(slug: String) async throws -> Story {
        guard let doc = try await articles(where: "slug", "equals", slug, limit: 1, depth: 2).first else {
            throw Failure.notFound("That story")
        }
        let section = doc["section"] as? String ?? ""
        let desk: Desk = switch section {
        case "news": .news
        case "sports": .sports
        case "features": .features
        case "opinion": .opinion
        default: SmartPaste.desk(for: section + " " + (doc["kicker"] as? String ?? "")) ?? .news
        }

        var photos: [WebPhoto] = []
        var credited: [Int] = []                   // photos whose credit the page prints as a staff link
        func add(_ media: Any?, caption: String?) {
            guard let m = media as? [String: Any], let path = m["url"] as? String,
                  let url = URL(string: path, relativeTo: site)?.absoluteURL else { return }
            let writeIn = (m["writeInPhotographer"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if writeIn.isEmpty, m["photographer"] != nil, !(m["photographer"] is NSNull) { credited.append(photos.count) }
            photos.append(WebPhoto(url: url, filename: m["filename"] as? String ?? url.lastPathComponent,
                                   caption: SmartPaste.clean(caption ?? ""), credit: writeIn))
        }
        add(doc["featuredImage"], caption: doc["imageCaption"] as? String)

        var body: [String] = []
        let root = ((doc["content"] as? [String: Any])?["root"] as? [String: Any])?["children"] as? [[String: Any]] ?? []
        for node in root {
            switch node["type"] as? String {
            case "paragraph", "heading", "quote":
                body.append(paragraph(node))
            case "list":
                for item in node["children"] as? [[String: Any]] ?? [] { body.append(paragraph(item)) }
            case "upload":
                add(node["value"], caption: (node["fields"] as? [String: Any])?["caption"] as? String)
            case "block":
                let fields = node["fields"] as? [String: Any] ?? [:]
                for img in fields["images"] as? [[String: Any]] ?? [] {
                    add(img["image"], caption: img["caption"] as? String)
                }
            default: break
            }
        }
        body = body.filter { !$0.isEmpty }

        // the page: bylines and photo credits
        let page = pageURL(section: section, published: doc["publishedDate"] as? String, slug: slug)
        let html = (try? await text(page)) ?? ""
        var authors = names(in: html)
        if authors.isEmpty {
            authors = (doc["writeInAuthors"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String ?? $0 as? String }
        }
        let author = SmartPaste.authors(authors.joined(separator: ", "))
        let credits = photoCredits(in: html)
        if credits.count == credited.count {
            for (i, k) in credited.enumerated() { photos[k].credit = credits[i] }
        }
        let titles = bylineTitles(in: html, authors: authors.count)
        let title = titles.isEmpty ? SmartPaste.defaultTitle(author, desk: desk, staff: []) : combined(titles)

        let headline = Markup.escape(SmartPaste.clean(doc["plainTitle"] as? String ?? ""))
        let kicker = SmartPaste.kicker(from: doc["kicker"] as? String ?? "")
        return Story(page: page, desk: desk, headline: headline, kicker: kicker, author: author, authorTitle: title, body: body, photos: photos)
    }

    /// Downloads the pictures into the media folder; one already there (same file from the site) is reused.
    static func download(_ photos: [WebPhoto], into dir: URL, keeping existing: [Photo]) async -> [Photo] {
        var out: [Photo] = []
        for w in photos {
            if var p = existing.first(where: { matches($0, w) }) {
                p.caption = w.caption.isEmpty ? p.caption : w.caption
                p.credit = w.credit.isEmpty ? p.credit : w.credit
                out.append(p); continue
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request(w.url)),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let dest = dir.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + w.filename)
            guard (try? data.write(to: dest)) != nil else { continue }
            out.append(Photo(path: dest.path, caption: w.caption, credit: w.credit))
        }
        return out
    }

    /// A stored photo is the website's picture when it was downloaded from the same file.
    static func matches(_ p: Photo, _ w: WebPhoto) -> Bool {
        let name = URL(fileURLWithPath: p.path).lastPathComponent
        return name == w.filename || name.hasSuffix("-" + w.filename)
    }

    // MARK: the API

    private static func articles(where field: String, _ op: String, _ value: String, limit: Int, depth: Int = 0) async throws -> [[String: Any]] {
        var c = URLComponents(url: site.appendingPathComponent("api/articles"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "where[\(field)][\(op)]", value: value),
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "depth", value: String(depth)),
                        URLQueryItem(name: "sort", value: "-publishedDate")]
        let (data, response) = try await URLSession.shared.data(for: request(c.url!))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { throw Failure.unreadable(value) }
        return docs
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Typeset (The Polytechnic layout)", forHTTPHeaderField: "User-Agent")
        return r
    }

    private static func text(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.notFound(url.path) }
        return String(decoding: data, as: UTF8.self)
    }

    /// /<section>/<yyyy>/<mm>/<slug>, dated the way the site files it (Troy time).
    private static func pageURL(section: String, published: String?, slug: String) -> URL {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = published.flatMap { iso.date(from: $0) } ?? Date()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let d = cal.dateComponents([.year, .month], from: date)
        return site.appendingPathComponent(String(format: "%@/%04d/%02d/%@", section, d.year ?? 0, d.month ?? 0, slug))
    }

    // MARK: rich text

    /// One paragraph of the site's rich text as the stored markup, italics and bold kept.
    private static func paragraph(_ node: [String: Any]) -> String {
        let s = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 12)
        func walk(_ n: [String: Any]) {
            switch n["type"] as? String {
            case "text":
                let format = n["format"] as? Int ?? 0
                var traits: NSFontDescriptor.SymbolicTraits = []
                if format & 1 != 0 { traits.insert(.bold) }
                if format & 2 != 0 { traits.insert(.italic) }
                let f = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 12) ?? base
                s.append(NSAttributedString(string: n["text"] as? String ?? "", attributes: [.font: f]))
            case "linebreak", "tab":
                s.append(NSAttributedString(string: " ", attributes: [.font: base]))
            default:
                for c in n["children"] as? [[String: Any]] ?? [] { walk(c) }
            }
        }
        walk(node)
        return SmartPaste.clean(Markup.paragraphs(from: s).joined(separator: " "))
    }

    // MARK: the page

    /// Author names from the page's article data.
    private static func names(in html: String) -> [String] {
        let pattern = #"<script type="application/ld\+json">(.*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let data = ns.substring(with: m.range(at: 1)).data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (d["@type"] as? String)?.hasSuffix("Article") == true else { continue }
            if let list = d["author"] as? [[String: Any]] { return list.compactMap { $0["name"] as? String } }
            if let one = d["author"] as? [String: Any], let n = one["name"] as? String { return [n] }
        }
        return []
    }

    /// The italic titles under the byline ("Editor in Chief"), one per author, from the story's header.
    private static func bylineTitles(in html: String, authors: Int) -> [String] {
        let header = html.range(of: "article-body").map { String(html[..<$0.lowerBound]) } ?? html
        let titles = matches(#"<p class="[^"]*\bitalic\b[^"]*\btext-text-main\b[^"]*">([^<]+)</p>"#, in: header)
        return Array(titles.prefix(max(authors, 1)))
    }

    /// Photo credits in page order ("Sam Rivera/The Polytechnic"): the staff link set beside each caption.
    private static func photoCredits(in html: String) -> [String] {
        let body = html.range(of: "<article").map { String(html[$0.lowerBound...]) } ?? html
        // the gallery sets "/The Polytechnic" after the link, the single photos inside it
        return matches(#"(<a class="hover:opacity-80 transition-opacity" href="/staff/[^"]*">.*?</a>[^<]*)"#, in: body)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            let raw = ns.substring(with: $0.range(at: 1))
                .replacingOccurrences(of: "<!-- -->", with: "")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            return SmartPaste.clean(unescaped(raw))
        }
    }

    /// HTML entities undone (&amp;, &#39;, &#x2019;, &nbsp;).
    private static func unescaped(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = "", rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var ch: String? = named[name]
                if name.hasPrefix("#x") || name.hasPrefix("#X") { ch = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { ch = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                if let ch { out += ch; rest = after[after.index(after: semi)...]; continue }
            }
            out += "&"; rest = after
        }
        return out + rest
    }

    /// One title for a shared byline: "Senior Reporters" when they match, joined with "and" when they don't.
    private static func combined(_ titles: [String]) -> String {
        let distinct = titles.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count == 1, titles.count > 1, let t = distinct.first,
           ["reporter", "editor", "writer", "columnist", "photographer", "contributor", "correspondent"].contains(where: { t.lowercased().hasSuffix($0) }) {
            return t + "s"
        }
        return distinct.count == 1 ? distinct[0] : distinct.joined(separator: " and ")
    }

    private static func normalized(_ s: String) -> String {
        Markup.plain(s).lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
