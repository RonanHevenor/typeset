import Foundation

/// A .typeset file: the whole issue in one file that another copy of Typeset opens as it was — the stories, the
/// layout, and every picture and ad it uses. Inside it's a zip archive: `issue.json`, with picture paths written
/// as `media:<name>`, and a `Media` folder holding those files. The sample pictures (`seed:`) ship with the app
/// and stay as they are.
enum IssueFile {
    static let fileExtension = "typeset"
    static let typeIdentifier = "edu.rpi.poly.galley.issue"
    private static let mediaPrefix = "media:"

    enum Failure: LocalizedError {
        case notAnIssue, tool(String)
        var errorDescription: String? {
            switch self {
            case .notAnIssue: "That file isn't a Typeset issue."
            case .tool(let why): why
            }
        }
    }

    /// Writes the issue and its pictures to `url`. Returns the pictures that couldn't be found, which go out
    /// without their files.
    @discardableResult
    static func write(_ issue: Issue, to url: URL) throws -> [String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("typeset-export-" + UUID().uuidString)
        let media = dir.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var packed: [String: String] = [:]           // original path → path inside the file
        var used: Set<String> = []
        var missing: [String] = []
        func pack(_ path: String) -> String {
            if path.isEmpty || path.hasPrefix("seed:") || path.hasPrefix(mediaPrefix) { return path }
            if let p = packed[path] { return p }
            guard let src = IssueStore.imageURL(for: path), fm.fileExists(atPath: src.path) else {
                missing.append(URL(fileURLWithPath: path).lastPathComponent)
                packed[path] = path
                return path
            }
            var name = src.lastPathComponent
            if used.contains(name) { name = UUID().uuidString.prefix(8) + "-" + name }
            used.insert(name)
            try? fm.copyItem(at: src, to: media.appendingPathComponent(name))
            packed[path] = mediaPrefix + name
            return mediaPrefix + name
        }

        var out = issue
        // the copies of component versions no page uses any more stay in memory for undo, but not in the file
        out.pruneComponentVersions()
        for i in out.articles.indices {
            for k in out.articles[i].photos.indices { out.articles[i].photos[k].path = pack(out.articles[i].photos[k].path) }
        }
        for i in out.extras.indices { out.extras[i].path = pack(out.extras[i].path) }
        try IssueStore.encoder().encode(out).write(to: dir.appendingPathComponent("issue.json"))

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString.prefix(6)).zip")
        try ditto(["-c", "-k", "--norsrc", dir.path, tmp.path])
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
        return missing
    }

    /// The pictures `write` would have to leave out because their files can't be found.
    static func missingPictures(_ issue: Issue) -> [String] {
        let fm = FileManager.default
        var seen: Set<String> = [], out: [String] = []
        let paths = issue.articles.flatMap { $0.photos.map(\.path) } + issue.extras.map(\.path)
        for path in paths where !(path.isEmpty || path.hasPrefix("seed:") || path.hasPrefix(mediaPrefix)) && seen.insert(path).inserted {
            if let src = IssueStore.imageURL(for: path), fm.fileExists(atPath: src.path) { continue }
            out.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        return out
    }

    /// The issue in a .typeset file, its pictures copied into `mediaDir` and pointed at there.
    static func read(_ url: URL, mediaDir: URL) throws -> Issue {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("typeset-import-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        do { try ditto(["-x", "-k", url.path, dir.path]) } catch { throw Failure.notAnIssue }
        guard var issue = IssueStore.load(from: dir.appendingPathComponent("issue.json")) else { throw Failure.notAnIssue }

        var placed: [String: String] = [:]
        func unpack(_ path: String) -> String {
            guard path.hasPrefix(mediaPrefix) else { return path }
            if let p = placed[path] { return p }
            let name = String(path.dropFirst(mediaPrefix.count))
            let src = dir.appendingPathComponent("Media").appendingPathComponent(name)
            var dest = mediaDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path), !fm.contentsEqual(atPath: dest.path, andPath: src.path) {
                dest = mediaDir.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + name)
            }
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: src, to: dest) }
            placed[path] = dest.path
            return dest.path
        }
        for i in issue.articles.indices {
            for k in issue.articles[i].photos.indices { issue.articles[i].photos[k].path = unpack(issue.articles[i].photos[k].path) }
        }
        for i in issue.extras.indices { issue.extras[i].path = unpack(issue.extras[i].path) }
        return issue
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.tool(why.isEmpty ? "Couldn't write the file." : why)
        }
    }
}
