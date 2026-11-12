import AppKit

/// Phase 1 (Files): Save, Open, Revert, New Issue and the library, driven without any panels.
extension SelfTest {
    @MainActor
    static func files(_ report: (String, Bool, String) -> Void, data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        let fm = FileManager.default
        let dir = data.appendingPathComponent("Files", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // a .typeset file unpacks its pictures into the media folder, so pictures are compared by file name
        func json(_ i: Issue) -> String {
            let text = String(decoding: (try? IssueStore.encoder().encode(i)) ?? Data(), as: UTF8.self)
            return text.replacingOccurrences(of: #""path" : "[^"]*/"#, with: #""path" : ""#, options: .regularExpression)
        }
        func backups() -> [String] { ((try? fm.contentsOfDirectory(atPath: data.path)) ?? []).filter { $0.hasPrefix("issue-before-open-") } }
        backups().forEach { try? fm.removeItem(at: data.appendingPathComponent($0)) }

        // 15. Save, reopen, Revert
        let s = IssueStore()
        if s.issue.layout == nil { s.generate() }
        let pic = IssueStore.mediaDir.appendingPathComponent("files-test.png")
        try? Data(repeating: 9, count: 64).write(to: pic)
        if !s.issue.articles.isEmpty { s.issue.articles[0].photos.insert(Photo(path: pic.path, caption: "Files", credit: "A/B"), at: 0) }
        s.saveNow()
        let a = dir.appendingPathComponent("Issue A.typeset")
        let savedJSON = json(s.issue)
        do {
            try s.save(to: a)
            check("Save writes the .typeset file and makes it the issue's file",
                  fm.fileExists(atPath: a.path) && s.fileURL == a && !s.isEdited && s.documentTitle == "Issue A", s.documentTitle)
            let entry = Library.shared.entries(.issue).first { $0.path == a.standardizedFileURL.path }
            check("  it goes in the library with a thumbnail of page 1",
                  entry != nil && entry.flatMap { Library.shared.thumbnailImage($0) } != nil, entry?.thumbnail ?? "no entry")

            s.issue.articles[0].headline += " (edited)"
            s.saveNow()
            check("an edit marks the issue edited", s.isEdited && s.canRevert)
            s.issue.articles[0].headline = String(s.issue.articles[0].headline.dropLast(" (edited)".count))
            s.saveNow()
            check("  undoing it by hand clears the mark", !s.isEdited)
            s.issue.articles[0].headline += " (edited)"
            s.saveNow()

            let relaunched = IssueStore()
            check("a relaunch remembers the file and that it has unsaved changes",
                  relaunched.fileURL == a && relaunched.isEdited, relaunched.fileURL?.lastPathComponent ?? "Untitled")

            let other = IssueStore()
            try other.open(a)
            check("save → reopen gives the same issue", json(other.issue) == savedJSON && other.fileURL == a && !other.isEdited,
                  "\(json(other.issue).count) vs \(savedJSON.count) bytes")

            try s.revert()
            check("Revert to Saved goes back to the file and keeps the changes as a backup",
                  json(s.issue) == savedJSON && !s.isEdited && !backups().isEmpty, "\(backups().count) backup(s)")
        } catch { check("save → reopen gives the same issue", false, "\(error)") }

        // 16. New Issue saves the current one first
        do {
            let volume = s.issue.volume, edition = s.issue.edition
            s.issue.articles[0].headline = "Saved before the new issue"
            s.saveNow()
            var asked = false
            let started = try s.newIssue { asked = true; return nil }
            let back = try IssueFile.read(a, mediaDir: IssueStore.mediaDir)
            check("New Issue saves an edited issue to its own file without asking",
                  started && !asked && back.articles.first?.headline == "Saved before the new issue")
            check("  and starts a blank issue: same publication and volume, next edition, Untitled",
                  s.issue.articles.isEmpty && s.issue.layout == nil && s.issue.volume == volume
                    && s.issue.edition == IssueStore.nextEdition(after: edition) && s.issue.edition != edition
                    && s.fileURL == nil && !s.isEdited, "Ed. \(edition) → \(s.issue.edition)")

            s.newArticle()
            s.issue.articles[0].headline = "Never saved"
            s.saveNow()
            let edition2 = s.issue.edition
            let cancelled = try s.newIssue { nil }
            check("New Issue on an Untitled issue with work in it asks where; cancelling keeps the issue",
                  !cancelled && s.issue.articles.first?.headline == "Never saved" && s.issue.edition == edition2)
            let b = dir.appendingPathComponent("Issue B.typeset")
            asked = false
            let started2 = try s.newIssue { asked = true; return b }
            let backB = try? IssueFile.read(b, mediaDir: IssueStore.mediaDir)
            check("  saving there writes it before the new issue starts",
                  started2 && asked && backB?.articles.first?.headline == "Never saved" && s.issue.articles.isEmpty
                    && s.issue.edition == IssueStore.nextEdition(after: edition2))
            asked = false
            _ = try s.newIssue { asked = true; return nil }
            check("  a blank Untitled issue isn't saved first", !asked)
            check("editions count on", IssueStore.nextEdition(after: "III") == "IV" && IssueStore.nextEdition(after: "XIX") == "XX"
                  && IssueStore.nextEdition(after: "12") == "13" && IssueStore.nextEdition(after: "Special") == "Special")
        } catch { check("New Issue saves first", false, "\(error)") }

        // 17. the library follows a moved file, shows a missing one, and never deletes on Remove
        do {
            let lib = Library(folder: dir.appendingPathComponent("Lib", isDirectory: true))
            try? fm.createDirectory(at: lib.thumbnails.deletingLastPathComponent(), withIntermediateDirectories: true)
            let c = dir.appendingPathComponent("Issue C.typeset")
            try IssueFile.write(s.issue, to: c)
            let id = lib.note(c, kind: .issue)
            let moved = dir.appendingPathComponent("Moved", isDirectory: true).appendingPathComponent("Renamed C.typeset")
            try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: c, to: moved)
            let found = lib.resolve(id)
            let reread = Library(folder: dir.appendingPathComponent("Lib", isDirectory: true)).entries(.issue).first
            check("a library entry follows a moved and renamed file (bookmark)",
                  found?.standardizedFileURL.path == moved.standardizedFileURL.path && reread?.path == moved.standardizedFileURL.path
                    && reread?.name == "Renamed C", found?.path ?? "not found")
            try fm.removeItem(at: moved)
            check("  a deleted file shows as missing", lib.location(of: lib.entries(.issue)[0]) == nil)
            lib.locate(id, at: b(dir))
            check("  Locate… points it at another file", lib.resolve(id)?.lastPathComponent == "Issue B.typeset")
            lib.remove(id)
            check("  Remove from Library leaves the file where it is", lib.entries(.issue).isEmpty && fm.fileExists(atPath: b(dir).path))

            // the issue's own file follows a move too
            let o = IssueStore()
            try o.open(a)
            let a2 = dir.appendingPathComponent("Moved", isDirectory: true).appendingPathComponent("Issue A moved.typeset")
            try fm.moveItem(at: a, to: a2)
            o.saveNow()
            let follows = o.resolvedFileURL()?.standardizedFileURL.path == a2.standardizedFileURL.path && o.documentTitle == "Issue A moved"
            try o.save(to: o.resolvedFileURL()!)
            check("  Save after the file was moved writes to where it went", follows && fm.fileExists(atPath: a2.path) && !fm.fileExists(atPath: a.path))
        } catch { check("a library entry follows a moved file", false, "\(error)") }
        reviewFixes(check, dir: dir, pic: pic)
        try? fm.removeItem(at: pic)
    }

    /// 18. After review: a stale document.json, a file renamed while open, a save that would drop pictures, and
    /// library entries this build can't read.
    @MainActor
    private static func reviewFixes(_ check: (String, Bool, String) -> Void, dir: URL, pic: URL) {
        let fm = FileManager.default
        let work = IssueStore.saveURL, docURL = IssueStore.documentStateURL
        let keptWork = try? Data(contentsOf: work), keptDoc = try? Data(contentsOf: docURL)
        defer {
            if let keptWork { try? keptWork.write(to: work) } else { try? fm.removeItem(at: work) }
            if let keptDoc { try? keptDoc.write(to: docURL) } else { try? fm.removeItem(at: docURL) }
        }
        do {
            // the working copy goes missing while document.json still names a file: the sample must not take it over
            let d = dir.appendingPathComponent("Issue D.typeset")
            let s = IssueStore()
            if s.issue.layout == nil { s.generate() }
            try s.save(to: d)
            let before = try Data(contentsOf: d)
            s.flushSave()
            try fm.removeItem(at: work)
            let sample = IssueStore()
            if !sample.issue.articles.isEmpty { sample.issue.articles[0].headline += " (sample edit)" }
            sample.saveNow()
            sample.flushSave()
            let next = IssueStore()
            check("a stale document.json doesn't tie the sample issue to the last file",
                  sample.fileURL == nil && next.fileURL == nil && (try? Data(contentsOf: d)) == before,
                  next.fileURL?.lastPathComponent ?? "Untitled")

            // renamed in the Finder while open: coming back to Typeset picks it up
            let o = IssueStore()
            try o.open(d)
            let renamed = dir.appendingPathComponent("Issue D renamed.typeset")
            try fm.moveItem(at: d, to: renamed)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            check("the title and Save target follow a file renamed while it's open",
                  o.documentTitle == "Issue D renamed" && o.fileURL?.standardizedFileURL.path == renamed.standardizedFileURL.path && !o.fileIsGone,
                  o.documentTitle)
            try fm.removeItem(at: renamed)
            check("  a deleted file has no Save target, so Save asks where", o.fileIsGone && o.saveTarget() == nil, "")

            // Save over a file whose pictures have gone missing asks first
            let e = dir.appendingPathComponent("Issue E.typeset")
            let p = IssueStore()
            if p.issue.layout == nil { p.generate() }
            try? Data(repeating: 7, count: 64).write(to: pic)
            p.issue.articles[0].photos.insert(Photo(path: pic.path, caption: "Kept", credit: "A/B"), at: 0)
            p.saveNow()
            try p.save(to: e)
            let full = try Data(contentsOf: e)
            try fm.removeItem(at: pic)
            p.issue.articles[0].headline += " (edited)"
            p.saveNow()
            var refused = false
            do { try p.save(to: e) } catch let m as MissingPictures { refused = m.names == ["files-test.png"] }
            check("Save over a file refuses to drop pictures that can't be found",
                  refused && (try? Data(contentsOf: e)) == full && p.isEdited, "")
            let dropped = try p.save(to: e, dropMissing: true)
            check("  and drops them once the user agrees", dropped == ["files-test.png"] && !p.isEdited, "")
            let fresh = dir.appendingPathComponent("Issue F.typeset")
            check("  a new file is still written, reporting what's missing", (try? p.save(to: fresh)) == ["files-test.png"], "")
        } catch { check("review fixes", false, "\(error)") }

        // library entries this build can't read are kept, and an unreadable library.json is kept aside
        let libDir = dir.appendingPathComponent("Lib2", isDirectory: true)
        try? fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let libFile = libDir.appendingPathComponent("library.json")
        let future = #"[{"id":"6F1C6A8E-0000-4000-8000-000000000001","kind":"deck","path":"/tmp/x.deck","lastOpened":"2026-11-03T10:00:00Z","shape":{"n":3}}]"#
        try? Data(future.utf8).write(to: libFile)
        let lib = Library(folder: libDir)
        lib.note(dir.appendingPathComponent("Issue F.typeset"), kind: .issue)
        let raw = (try? Data(contentsOf: libFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let deck = raw.first { $0["kind"] as? String == "deck" }
        check("a library entry of an unknown kind isn't shown as an issue, and is kept in the file",
              lib.entries(.issue).count == 1 && raw.count == 2 && (deck?["shape"] as? [String: Any])?["n"] as? Int == 3,
              "\(raw.count) entries in the file")
        try? Data(#"[{"kind":"issue","pa"#.utf8).write(to: libFile)
        _ = Library(folder: libDir)
        let aside = ((try? fm.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasPrefix("library-unreadable-") }
        check("  an unreadable library.json is kept aside before anything writes over it", !aside.isEmpty, "")
    }

    private static func b(_ dir: URL) -> URL { dir.appendingPathComponent("Issue B.typeset") }
}
