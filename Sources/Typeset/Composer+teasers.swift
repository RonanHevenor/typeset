import AppKit

// How a group of teaser-headline frames sets (phase 4): what `teaserSetting` did for the three teasers over the
// nameplate when the app drew the front header itself. Every teaser-headline frame in one placed component sets
// at one size and line count, chosen together.

extension Composer {
    struct TeaserSetting: Equatable {
        var size: CGFloat
        var lines: Int
        var lineHeight: CGFloat
        /// From the frame's top to the type's: the house teaser starts 28 pt under the bar's top for two lines
        /// and 21.5 for three or more, so a third line takes some of the air over the headline, not the nameplate's.
        var drop: CGFloat
        var height: CGFloat { CGFloat(lines) * size * lineHeight + 2 }
    }

    /// The teaser setting of a group of frames: the house 16 pt (or the frames' own size) wherever the headlines
    /// allow, two lines each, or three (set a little tighter, started higher) when one needs them. Only a headline
    /// that won't go in three lines at that size brings the size down, half a point at a time, with as many lines
    /// as the frame holds; a story's own teaser text (a shorter headline for the front) keeps that from happening.
    /// No teaser is ever cut short with an ellipsis. `frames` are the frames' rects on the page with their stories.
    func teaserSetting(_ frames: [(rect: CGRect, article: Article?)], size start: CGFloat = 16) -> TeaserSetting {
        typealias F = HouseStyle.Front
        let twoLines = F.teaserTop - F.teaserBar.minY, more = F.teaserTopThreeLines - F.teaserBar.minY
        let room = frames.map(\.rect.height).min() ?? 0
        func fits(_ t: TeaserSetting) -> Bool {
            t.drop + t.height <= room && !frames.contains { r, a in
                guard let a else { return false }
                return height(of: Self.teaser(a.teaserHeadline, size: t.size, lineHeight: t.lineHeight), width: r.width) > t.height - 1
            }
        }
        var size = start
        var last: TeaserSetting?
        while size >= 11 {
            for lines in 2...4 {
                let t = TeaserSetting(size: size, lines: lines, lineHeight: lines == 2 ? 1.21 : 1.15, drop: lines == 2 ? twoLines : more)
                guard t.drop + t.height <= room else { break }
                last = t
                if fits(t) { return t }
            }
            size -= 0.5
        }
        return last ?? TeaserSetting(size: 11, lines: 3, lineHeight: 1.15, drop: more)
    }

    /// The teaser setting of every teaser-headline frame in a placed component, worked out once for the group.
    func teaserSetting(of rc: ResolvedComponent, articles: [Article.ID: Article]) -> TeaserSetting {
        let frames = rc.version.frames.filter { $0.type == .teaserHeadline }
        let start = frames.compactMap(\.size).min() ?? 16
        return teaserSetting(frames.map { (rc.rect($0.box), rc.placed.fill(for: $0)?.article.flatMap { articles[$0] }) }, size: start)
    }

    /// What an issue field says on a page: the frame's template with the issue's facts put in, or the value of its
    /// own type. A part in square brackets goes when a fact inside it is empty ("[{desk}  •  ]{page}").
    static func fieldText(_ f: Frame, issue: Issue, number: Int, section: String) -> String {
        func value(_ key: String) -> String? {
            switch key {
            case "page": return "\(number)"
            case "volume": return issue.volume
            case "edition": return issue.edition
            case "desk": return section
            case "date":
                let df = DateFormatter()
                df.dateFormat = f.dateFormat ?? Frame.defaultDateFormat
                return df.string(from: issue.date)
            default: return nil
            }
        }
        guard let template = f.template else {
            let key: String
            switch f.type {
            case .pageNumber: key = "page"; case .volume: key = "volume"; case .edition: key = "edition"
            case .desk: key = "desk"; case .date: key = "date"
            default: return ""
            }
            return value(key) ?? ""
        }
        // substitute one run, saying whether a fact in it was empty
        func expand(_ run: Substring) -> (String, empty: Bool) {
            var out = "", empty = false, rest = run
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                out += rest[..<open]
                let key = String(rest[rest.index(after: open)..<close])
                if let v = value(key) { if v.isEmpty { empty = true }; out += v } else { out += rest[open...close] }
                rest = rest[rest.index(after: close)...]
            }
            return (out + rest, empty)
        }
        var out = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            out += expand(rest[..<open]).0
            let (part, empty) = expand(rest[rest.index(after: open)..<close])
            if !empty { out += part }
            rest = rest[rest.index(after: close)...]
        }
        return out + expand(rest).0
    }
}
