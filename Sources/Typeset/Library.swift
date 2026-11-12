import AppKit
import Observation

/// One file in the library: an issue, template or component the user has opened or saved.
struct LibraryEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case issue, template, component
        var id: String { rawValue }
        var title: String {
            switch self {
            case .issue: "Issues"
            case .template: "Templates"
            case .component: "Components"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    /// Where the file was last seen. Shown, and used when the bookmark can't find it.
    var path: String
    /// A macOS bookmark, which still finds the file after it has been moved or renamed.
    var bookmark: Data?
    var lastOpened = Date()
    /// Page 1 as a PNG in the library's Thumbnails folder.
    var thumbnail: String?

    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    init(kind: Kind, path: String) { self.kind = kind; self.path = path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        // a kind this build doesn't know (from a newer Typeset) fails the entry, which the library keeps as it is
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .issue
        path = try c.decode(String.self, forKey: .path)
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
        lastOpened = (try? c.decodeIfPresent(Date.self, forKey: .lastOpened)) ?? Date()
        thumbnail = try? c.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}

/// The library: a list of paths to the files the user has opened or saved, kept in
/// `Application Support/Typeset/library.json`. It works as a really good Open Recent. Removing an entry never
/// touches the file.
@Observable
final class Library {
    static let shared = Library(folder: IssueStore.supportDir)

    private(set) var entries: [LibraryEntry] = []
    /// Bumped when the system's recent-documents list changes, so Open Recent redraws.
    var recentsChanged = 0
    /// Bumped when a thumbnail file is rewritten, so the Library window reloads it.
    var thumbnailsChanged = 0
    @ObservationIgnored let url: URL
    @ObservationIgnored let thumbnails: URL
    /// Entries this build can't read (a kind from a newer Typeset, say), written back untouched on every save.
    @ObservationIgnored private var unread: [LibraryJSON] = []

    init(folder: URL) {
        url = folder.appendingPathComponent("library.json")
        thumbnails = folder.appendingPathComponent("Thumbnails", isDirectory: true)
        if let data = try? Data(contentsOf: url) {
            // lenient, as everywhere: an entry that can't be read is set aside on its own and kept in the file
            struct Lenient: Decodable {
                let e: LibraryEntry?, raw: LibraryJSON?
                init(from d: Decoder) throws { e = try? LibraryEntry(from: d); raw = e == nil ? try? LibraryJSON(from: d) : nil }
            }
            if let list = try? IssueStore.decoder().decode([Lenient].self, from: data) {
                entries = list.compactMap(\.e)
                unread = list.compactMap(\.raw)
            } else {
                // not a list at all (cut short, say): keep it aside before the next save writes over it
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
                try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("library-unreadable-\(f.string(from: Date())).json"))
            }
        }
    }

    func entries(_ kind: LibraryEntry.Kind) -> [LibraryEntry] {
        entries.filter { $0.kind == kind }.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func save() {
        let all = entries.compactMap { e in (try? IssueStore.encoder().encode(e)).flatMap { try? IssueStore.decoder().decode(LibraryJSON.self, from: $0) } } + unread
        if let data = try? IssueStore.encoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// The file a bookmark points at, if it's still there and not in the Trash.
    static func resolve(bookmark: Data) -> URL? {
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: u.path), !u.path.contains("/.Trash/") else { return nil }
        return u
    }

    /// Where the entry's file is now, without changing anything: its bookmark first (which follows a move or
    /// rename), then its path. Nil when it's missing.
    func location(of e: LibraryEntry) -> URL? {
        if let b = e.bookmark, let u = Self.resolve(bookmark: b) { return u }
        return FileManager.default.fileExists(atPath: e.path) ? URL(fileURLWithPath: e.path) : nil
    }

    /// Where the entry's file is now (see `location(of:)`), bringing its path and bookmark up to date when it
    /// has moved. Nil when it's missing.
    @discardableResult
    func resolve(_ id: LibraryEntry.ID) -> URL? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        guard let u = location(of: entries[i]) else { return nil }
        if u.standardizedFileURL.path != entries[i].path {
            entries[i].path = u.standardizedFileURL.path
            entries[i].bookmark = (try? u.bookmarkData()) ?? entries[i].bookmark
            save()
        }
        return u
    }

    /// Brings every entry's path up to date with where its file is now (the Library window does this on opening).
    func refresh() {
        for e in entries { resolve(e.id) }
    }

    /// Adds the file, or brings its entry up to date (path, bookmark, when, thumbnail).
    @discardableResult
    func note(_ file: URL, kind: LibraryEntry.Kind, thumbnail: NSImage? = nil) -> LibraryEntry.ID {
        let path = file.standardizedFileURL.path
        refresh()
        let i = entries.firstIndex { $0.kind == kind && $0.path == path }
        var e = i.map { entries[$0] } ?? LibraryEntry(kind: kind, path: path)
        e.path = path
        e.bookmark = try? file.bookmarkData()
        e.lastOpened = Date()
        if let thumbnail, let png = Self.png(thumbnail) {
            try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            let name = e.id.uuidString + ".png"
            if (try? png.write(to: thumbnails.appendingPathComponent(name), options: .atomic)) != nil { e.thumbnail = name; thumbnailsChanged &+= 1 }
        }
        if let i { entries[i] = e } else { entries.append(e) }
        save()
        return e.id
    }

    /// Locate…: the entry's file is now at `file`.
    func locate(_ id: LibraryEntry.ID, at file: URL) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].path = file.standardizedFileURL.path
        entries[i].bookmark = try? file.bookmarkData()
        save()
    }

    /// Remove from Library. The file stays where it is.
    func remove(_ id: LibraryEntry.ID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let t = entries[i].thumbnail { try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(t)) }
        entries.remove(at: i)
        save()
    }

    func thumbnailImage(_ e: LibraryEntry) -> NSImage? {
        _ = thumbnailsChanged
        return e.thumbnail.flatMap { NSImage(contentsOf: thumbnails.appendingPathComponent($0)) }
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Any JSON value, so a library entry this build can't read is written back as it was.
enum LibraryJSON: Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([LibraryJSON]), object([String: LibraryJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([LibraryJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: LibraryJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
