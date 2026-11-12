import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Which `.typeset` file the issue being worked on belongs to, and whether it has changed since it was saved.
/// The issue itself still autosaves to the working copy (`issue.json`) every few seconds; this records the file
/// that Save writes to. It's kept in `document.json` beside the working copy, so it survives a relaunch.
struct IssueDocument: Codable, Equatable {
    /// The `.typeset` file, or nil for an issue that has never been saved (Untitled).
    var url: URL?
    /// A macOS bookmark to the file, which still finds it after it has been moved or renamed.
    var bookmark: Data?
    /// SHA-256 of the issue as encoded when it was last saved, opened or started. Nil means "never saved".
    var savedDigest: String?
    /// The issue differs from `savedDigest`. Worked out each time the working copy is written.
    var isEdited = false
    /// The window is editing a template (a `.typesettemplate` file), not an issue (IssueStore+Templates.swift).
    var isTemplate = false

    enum CodingKeys: String, CodingKey { case url, bookmark, savedDigest, isTemplate }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
        savedDigest = try? c.decodeIfPresent(String.self, forKey: .savedDigest)
        isTemplate = ((try? c.decodeIfPresent(Bool.self, forKey: .isTemplate)) ?? nil) ?? false
    }
}

extension IssueStore {
    // MARK: state

    var fileURL: URL? { document.url }
    var isEdited: Bool { document.isEdited }
    /// Nothing in it worth keeping: no stories, no ads, and no pages, or only a template's pages with nothing filled.
    var isBlank: Bool {
        issue.articles.isEmpty && issue.extras.isEmpty
            && (issue.layout?.pages.allSatisfy { $0.stories.isEmpty && $0.insets.isEmpty && $0.components.allSatisfy(\.fills.isEmpty) } ?? true)
    }
    /// Would be lost by starting another issue: an edited file, or an Untitled issue with anything in it. A
    /// template counts once it has changed since it was opened or started.
    var needsSave: Bool { document.isTemplate ? isEdited : fileURL == nil ? !isBlank : isEdited }
    var canRevert: Bool { fileURL != nil && isEdited }

    /// The window's title: the file's name, or Untitled.
    var documentTitle: String { fileURL?.deletingPathExtension().lastPathComponent ?? (document.isTemplate ? "Untitled Template" : "Untitled") }

    static var documentStateURL: URL { supportDir.appendingPathComponent("document.json") }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func currentDigest() -> String? { (try? Self.encoder().encode(issue)).map(Self.digest) }

    /// Called from `init`: which file the working copy belongs to, from `document.json`. An issue that was
    /// worked on before files existed has no record, and comes back Untitled.
    func restoreDocument() {
        let fm = FileManager.default
        if loadProblem == nil, fm.fileExists(atPath: Self.saveURL.path),
           let data = try? Data(contentsOf: Self.documentStateURL),
           let d = try? Self.decoder().decode(IssueDocument.self, from: data) {
            document = d
            resolvedFileURL()
        } else {
            // the working copy isn't the one the record was about (the sample, after an unreadable or missing
            // issue.json): write the fresh record now, or a stale one would tie this issue to that file next launch
            document = IssueDocument()
            document.savedDigest = currentDigest()
            persistDocument()
        }
        document.isEdited = document.savedDigest == nil || currentDigest() != document.savedDigest
        // coming back to Typeset (from the Finder, say) picks up a file that was moved or renamed meanwhile
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followFile() }
        }
    }

    /// The file Save writes to without asking: the issue's file where it is now, or nil when it has none or it's gone.
    func saveTarget() -> URL? {
        let url = resolvedFileURL()
        return fileIsGone ? nil : url
    }

    /// Brings the title, proxy icon and Save target up to date with where the issue's file is now.
    func followFile() { resolvedFileURL() }

    /// The issue has a file, but it isn't where Typeset last saw it and its bookmark can't find it (deleted, or
    /// in the Trash).
    var fileIsGone: Bool {
        guard let url = document.url else { return false }
        return !FileManager.default.fileExists(atPath: url.path) || url.path.contains("/.Trash/")
    }

    /// Called from `saveNow` with what was just written to the working copy.
    func noteWorkingCopy(_ data: Data) {
        let edited = document.savedDigest == nil || Self.digest(data) != document.savedDigest
        if edited != document.isEdited { document.isEdited = edited }
    }

    func persistDocument() {
        if let data = try? Self.encoder().encode(document) { try? data.write(to: Self.documentStateURL, options: .atomic) }
    }

    /// Where the file is now, following its bookmark if it was moved or renamed. Updates `fileURL` to match.
    @discardableResult
    func resolvedFileURL() -> URL? {
        guard let url = document.url else { return nil }
        if let b = document.bookmark, let moved = Library.resolve(bookmark: b), moved.standardizedFileURL != url.standardizedFileURL {
            document.url = moved
            document.bookmark = try? moved.bookmarkData()
            persistDocument()
            return moved
        }
        return url
    }

    /// Marks the issue as saved in (or opened from) `url`, or as a fresh Untitled issue when `url` is nil.
    func markSaved(as url: URL?, template: Bool = false) {
        var d = IssueDocument()
        d.isTemplate = template
        d.url = url
        d.bookmark = try? url?.bookmarkData()
        d.savedDigest = currentDigest()
        d.isEdited = false
        document = d
        persistDocument()
        guard let url else { return }
        Library.shared.note(url, kind: template ? .template : .issue, thumbnail: pageOneThumbnail())
        // the system's recent list is the user's real one; a test run leaves it alone
        if ProcessInfo.processInfo.environment["GALLEY_DATA_DIR"] == nil {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            Library.shared.recentsChanged &+= 1
        }
    }

    // MARK: the steps, without any panels (the self-tests drive these)

    /// Writes the issue to `url` as a `.typeset` file and makes that the issue's file. Returns the pictures that
    /// couldn't be found, which go out without their files.
    /// Saving over a file that exists while some pictures can't be found would drop them from it, and it may be
    /// the only copy left: that throws `MissingPictures` unless `dropMissing` says the user agreed.
    @discardableResult
    func save(to url: URL, dropMissing: Bool = false) throws -> [String] {
        flushSave()
        if isEditingTemplate { try saveTemplate(to: url); return [] }
        if !dropMissing, FileManager.default.fileExists(atPath: url.path) {
            let missing = IssueFile.missingPictures(issue)
            if !missing.isEmpty { throw MissingPictures(file: url, names: missing) }
        }
        let missing = try IssueFile.write(issue, to: url)
        markSaved(as: url)
        return missing
    }

    /// Replaces the issue with the one in `url`. Unsaved work is kept as a backup beside the working copy first.
    func open(_ url: URL) throws {
        if url.pathExtension.lowercased() == IssueTemplate.fileExtension { try openTemplate(url); return }
        let opened = try IssueFile.read(url, mediaDir: Self.mediaDir)
        flushSave()
        if needsSave {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            try? FileManager.default.copyItem(at: Self.saveURL,
                                              to: Self.supportDir.appendingPathComponent("issue-before-open-\(f.string(from: Date())).json"))
        }
        replaceIssue(with: opened)
        markSaved(as: url)
    }

    /// Goes back to the file as it was last saved.
    func revert() throws {
        guard let url = resolvedFileURL() else { return }
        try open(url)
    }

    /// Starts a blank issue that keeps the publication and volume and takes the next edition. `saveTo` is asked
    /// where to save the current issue when it has never been saved; returning nil cancels. Returns whether the
    /// new issue was started.
    @discardableResult
    /// `template` (phase 8) is asked, after the save, which template the issue starts from; nil from it cancels.
    /// Without it the issue starts blank, with no pages.
    func newIssue(dropMissing: Bool = false, saveTo: () -> URL?, template: (() -> IssueTemplate?)? = nil) throws -> Bool {
        flushSave()
        if needsSave {
            guard let url = saveTarget() ?? saveTo() else { return false }
            try save(to: url, dropMissing: dropMissing)
        }
        var chosen: IssueTemplate?
        if let template {
            guard let t = template() else { return false }
            chosen = t
        }
        var fresh = Issue()
        fresh.publication = issue.publication
        fresh.volume = issue.volume
        fresh.edition = Self.nextEdition(after: issue.edition)
        if let chosen { fresh.start(from: chosen) }
        replaceIssue(with: fresh)
        markSaved(as: nil)
        return true
    }

    func replaceIssue(with new: Issue) {
        inPlace = nil
        canvasSelection = nil
        focusedPage = nil
        dragging = nil
        issue = new
        selection = issue.articles.first?.id
        undoManager?.removeAllActions()
        saveNow()
    }

    /// "III" → "IV", "12" → "13". Anything else stays as it is.
    static func nextEdition(after e: String) -> String {
        let t = e.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return String(n + 1) }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        let up = Array(t.uppercased())
        guard !up.isEmpty, up.allSatisfy({ values[$0] != nil }) else { return e }
        var n = 0
        for (i, c) in up.enumerated() {
            let v = values[c]!
            if i + 1 < up.count, values[up[i + 1]]! > v { n -= v } else { n += v }
        }
        n += 1
        var out = ""
        for (v, s) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                       (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v { out += s; n -= v }
        }
        return out
    }

    /// Page 1, 240 points wide, for the library. Nil before there are pages.
    func pageOneThumbnail() -> NSImage? {
        guard issue.layout != nil, let page = displayPages.first else { return nil }
        let w: CGFloat = 240, scale = w / HouseStyle.page.width
        let size = CGSize(width: w, height: (HouseStyle.page.height * scale).rounded())
        return NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            page.draw(guides: false)
            return true
        }
    }

    // MARK: the menu commands

    /// File › Save: to the issue's file, or asks where when it has never been saved.
    func saveCommand() {
        guard let url = resolvedFileURL() else { saveAsCommand(); return }
        if fileIsGone {
            guard let to = askWhereToSave(title: "Save “\(documentTitle)”",
                                          message: "“\(url.lastPathComponent)” was deleted or moved to the Trash. Choose where to save the issue.")
            else { return }
            write(to: to)
            return
        }
        write(to: url)
    }

    /// File › Save As…
    func saveAsCommand() {
        guard let url = askWhereToSave(title: "Save As") else { return }
        write(to: url)
    }

    /// Asks before a save that would drop pictures from a file that has them.
    func confirmDropping(_ m: MissingPictures) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Some pictures weren't found. Save “\(m.file.deletingPathExtension().lastPathComponent)” without them?"
        alert.informativeText = "Saving replaces the file, and these would no longer be in it: " + m.names.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Without Them")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @discardableResult
    private func write(to url: URL, dropMissing: Bool = false) -> Bool {
        do {
            let missing = try save(to: url, dropMissing: dropMissing)
            if !missing.isEmpty {
                fileAlert("Some pictures weren't found", "These were saved without their files: " + missing.joined(separator: ", ") + ".")
            }
            return true
        } catch let m as MissingPictures {
            return confirmDropping(m) && write(to: url, dropMissing: true)
        } catch {
            fileAlert("Couldn't save the issue", error.localizedDescription)
            return false
        }
    }

    func askWhereToSave(title: String, message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: isEditingTemplate ? IssueTemplate.typeIdentifier : IssueFile.typeIdentifier)]
        panel.title = title
        if let message { panel.message = message }
        if let url = fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else if isEditingTemplate {
            panel.nameFieldStringValue = "Template.\(IssueTemplate.fileExtension)"
        } else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            panel.nameFieldStringValue = "polytechnic-\(f.string(from: issue.date)).\(IssueFile.fileExtension)"
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// File › New Issue: saves this issue first (asking where if it has never been saved), then starts the next.
    func newIssueCommand(dropMissing: Bool = false) {
        do {
            try newIssue(dropMissing: dropMissing, saveTo: {
                askWhereToSave(title: "Save “\(documentTitle)”", message: "The \(isEditingTemplate ? "template" : "issue") you're working on is saved before the new issue starts.")
            }, template: { self.chooseTemplateForNewIssue() })
        } catch let m as MissingPictures {
            if confirmDropping(m) { newIssueCommand(dropMissing: true) }
        } catch {
            fileAlert("Couldn't save the issue, so no new issue was started", error.localizedDescription)
        }
    }

    /// File › Open…
    func openCommand() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: IssueFile.typeIdentifier), UTType(exportedAs: IssueTemplate.typeIdentifier)]
        panel.title = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPrompting(url)
    }

    /// Opens `url` (from Open…, Open Recent, the library or the Finder), offering to save unsaved work first.
    func openPrompting(_ url: URL) {
        if let current = fileURL, current.standardizedFileURL == url.standardizedFileURL, !isEdited { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            fileAlert("“\(url.lastPathComponent)” isn't there any more", "It was in \(url.deletingLastPathComponent().path).")
            return
        }
        if needsSave {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(documentTitle)” before opening “\(url.deletingPathExtension().lastPathComponent)”?"
            alert.informativeText = "If you don't save, your changes are kept as a backup in \(Self.supportDir.path)."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let target = saveTarget() ?? askWhereToSave(title: "Save “\(documentTitle)”"), write(to: target) else { return }
            case .alertThirdButtonReturn: break
            default: return
            }
        }
        do { try open(url) } catch { fileAlert("Couldn't open that file", error.localizedDescription) }
    }

    /// File › Revert to Saved.
    func revertCommand() {
        guard canRevert else { return }
        let alert = NSAlert()
        alert.messageText = "Revert “\(documentTitle)” to the saved version?"
        alert.informativeText = "Your changes since the last save are kept as a backup in \(Self.supportDir.path)."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try revert() } catch { fileAlert("Couldn't revert", error.localizedDescription) }
    }

    func fileAlert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }
}

/// Save would replace an existing file without pictures that can't be found any more.
struct MissingPictures: LocalizedError {
    var file: URL
    var names: [String]
    var errorDescription: String? {
        "These pictures weren't found, and saving would drop them from “\(file.lastPathComponent)”: " + names.joined(separator: ", ") + "."
    }
}

/// Puts the issue's file on the window: the proxy icon in the title bar and the dot in the close button while
/// there are unsaved changes.
struct DocumentWindowState: NSViewRepresentable {
    var url: URL?
    var edited: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let url = url, edited = edited
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            if w.representedURL != url { w.representedURL = url }
            if w.isDocumentEdited != edited { w.isDocumentEdited = edited }
        }
    }
}
