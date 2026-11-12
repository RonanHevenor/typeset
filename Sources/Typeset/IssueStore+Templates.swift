import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Templates in the window (phase 8). The window edits one document at a time, an issue or a template, as it
// swaps issues (decision 1): a template opens in place of the issue (asking to save it first, as Open does), as an
// issue with no stories whose pages carry only components, on the Pages canvas without the Content and Priority
// steps. Save writes the `.typesettemplate` file. The steps take URLs, so the self-tests drive them without panels;
// the menu commands add the panels.

/// A template New Issue can start from: the shipped one, or a file in the library.
struct TemplateChoice: Hashable {
    var name: String
    var url: URL?                          // nil: The Polytechnic, which ships with the app
    static let shipped = TemplateChoice(name: BuiltInTemplates.polytechnicName, url: nil)
}

extension IssueStore {
    var isEditingTemplate: Bool { document.isTemplate }

    // MARK: the steps

    /// Writes the template being edited to `url` and makes that its file.
    func saveTemplate(to url: URL) throws {
        flushSave()
        try IssueTemplate(issue: issue, name: url.deletingPathExtension().lastPathComponent).write(to: url)
        markSaved(as: url, template: true)
    }

    /// The window as a template editor on `t`: its pages and components, no stories. The publication, volume and
    /// edition stay the last issue's, so New Issue from here takes the next edition.
    private func editTemplate(_ t: IssueTemplate) {
        var e = Issue()
        e.publication = issue.publication; e.volume = issue.volume; e.edition = issue.edition
        e.stage = .pages
        var l = IssueLayout()
        l.columns = issue.layout?.columns ?? HouseStyle.columns(averageCharWidth: HouseStyle.averageCharWidth(of: "")).columns
        l.pages = IssueTemplate.clean(t.pages.isEmpty ? [PageLayout(isFront: true)] : t.pages)
        e.layout = l
        e.componentVersions = t.componentVersions
        replaceIssue(with: e)
    }

    /// Opens a `.typesettemplate` file for editing. Unsaved work is kept as a backup beside the working copy first.
    func openTemplate(_ url: URL) throws {
        let t = try IssueTemplate.read(url)
        flushSave()
        if needsSave {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            try? FileManager.default.copyItem(at: Self.saveURL, to: Self.supportDir.appendingPathComponent("issue-before-open-\(f.string(from: Date())).json"))
        }
        editTemplate(t)
        markSaved(as: url, template: true)
    }

    /// File › New Template: an Untitled template, starting from The Polytechnic. `saveTo` is asked where to save
    /// unsaved work first; returning nil cancels.
    @discardableResult
    func newTemplate(dropMissing: Bool = false, saveTo: () -> URL?) throws -> Bool {
        flushSave()
        if needsSave {
            guard let url = saveTarget() ?? saveTo() else { return false }
            try save(to: url, dropMissing: dropMissing)
        }
        editTemplate(BuiltInTemplates.polytechnic)
        markSaved(as: nil, template: true)
        return true
    }

    /// File › Save as Template…: the issue's pages and components, without its stories and fills, as a template
    /// file in the library. The issue stays open.
    func saveAsTemplate(to url: URL) throws {
        let t = IssueTemplate(issue: issue, name: url.deletingPathExtension().lastPathComponent)
        try t.write(to: url)
        Library.shared.note(url, kind: .template, thumbnail: thumbnail(of: t))
    }

    /// Page 1 of a template, for the library.
    func thumbnail(of t: IssueTemplate) -> NSImage? {
        var i = Issue()
        i.publication = issue.publication; i.volume = issue.volume; i.edition = issue.edition
        i.start(from: t)
        guard let page = composer.compose(i, exact: false).first else { return nil }
        let w: CGFloat = 240, scale = w / HouseStyle.page.width
        return NSImage(size: CGSize(width: w, height: (HouseStyle.page.height * scale).rounded()), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            page.draw(guides: false)
            return true
        }
    }

    // MARK: which template New Issue starts from

    /// The shipped template first, then the library's templates whose files are there, newest first.
    func templateChoices() -> [TemplateChoice] {
        [.shipped] + Library.shared.entries(.template).compactMap { e in
            Library.shared.location(of: e).map { TemplateChoice(name: e.name, url: $0) }
        }
    }

    static var lastTemplateURL: URL { supportDir.appendingPathComponent("last-template.json") }

    /// The template the last new issue was made from, as it's offered: the shipped one when it was that, or its
    /// file is gone from the library.
    func lastTemplateChoice(in choices: [TemplateChoice]) -> TemplateChoice {
        guard let data = try? Data(contentsOf: Self.lastTemplateURL),
              let path = try? JSONDecoder().decode([String: String].self, from: data)["path"] else { return .shipped }
        return choices.first { $0.url?.standardizedFileURL.path == path } ?? .shipped
    }

    func noteTemplateUsed(_ c: TemplateChoice) {
        let value = c.url.map { ["path": $0.standardizedFileURL.path] } ?? [:]
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: Self.lastTemplateURL, options: .atomic) }
        if let url = c.url { Library.shared.note(url, kind: .template) }
    }

    func loadTemplate(_ c: TemplateChoice) throws -> IssueTemplate {
        guard let url = c.url else { return BuiltInTemplates.polytechnic }
        return try IssueTemplate.read(url)
    }

    // MARK: pages and repeating components

    /// Duplicate on All Pages / on All Inside Pages: a copy of the component on every other page (or every inside
    /// page) that doesn't carry it yet, with empty frames; every placement of it is marked as repeating, so Add
    /// Page puts it on new pages too. One undo step.
    func duplicateOnAllPages(_ id: PlacedComponent.ID, inside: Bool) {
        guard let (page, p) = placedComponent(id) else { return }
        let mode: Repeat = inside ? .insidePages : .allPages
        edit(inside ? "Duplicate on All Inside Pages" : "Duplicate on All Pages") {
            for i in issue.layout!.pages.indices {
                for k in issue.layout!.pages[i].components.indices where issue.layout!.pages[i].components[k].component == p.component {
                    issue.layout!.pages[i].components[k].repeats = mode
                }
            }
            for i in issue.layout!.pages.indices where i != page && mode.applies(toFront: issue.layout!.pages[i].isFront)
                && !issue.layout!.pages[i].components.contains(where: { $0.component == p.component }) {
                var q = p
                q.id = UUID(); q.fills = []; q.repeats = mode
                issue.layout!.pages[i].components.append(q)
            }
        }
    }

    /// Stops a component repeating on pages added later. The copies already placed stay.
    func stopRepeating(_ id: PlacedComponent.ID) {
        guard let (_, p) = placedComponent(id) else { return }
        edit("Don't Repeat on New Pages") {
            for i in issue.layout!.pages.indices {
                for k in issue.layout!.pages[i].components.indices where issue.layout!.pages[i].components[k].component == p.component {
                    issue.layout!.pages[i].components[k].repeats = nil
                }
            }
        }
    }

    /// The template editor's page order: moves a page, and whichever page is first is the front.
    func movePage(_ from: Int, to: Int) {
        guard let l = issue.layout, l.pages.indices.contains(from), l.pages.indices.contains(to), from != to else { return }
        edit("Move Page") {
            let p = issue.layout!.pages.remove(at: from)
            issue.layout!.pages.insert(p, at: to)
            for i in issue.layout!.pages.indices { issue.layout!.pages[i].isFront = i == 0 }
        }
        focusedPage = to
    }

    /// The template editor's Remove Page: any page but the last one left; the first page is the front.
    func removeTemplatePage(_ i: Int) {
        guard let l = issue.layout, l.pages.indices.contains(i), l.pages.count > 1 else { return }
        edit("Remove Page") {
            issue.layout!.pages.remove(at: i)
            for k in issue.layout!.pages.indices { issue.layout!.pages[k].isFront = k == 0 }
        }
        canvasSelection = nil
        focusedPage = min(i, issue.layout!.pages.count - 1)
    }

    // MARK: the menu commands

    /// File › New Issue's question: which template, with the last one used selected. Nil cancels.
    func chooseTemplateForNewIssue() -> IssueTemplate? {
        var choices = templateChoices()
        let last = lastTemplateChoice(in: choices)
        let alert = NSAlert()
        alert.messageText = "New Issue"
        alert.informativeText = "Choose the template the new issue starts from. Its pages and components come with it; the stories are laid out around them."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: choices.map(\.name))
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "Other…")
        popup.selectItem(at: choices.firstIndex(of: last) ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var choice: TemplateChoice
        if popup.indexOfSelectedItem < choices.count {
            choice = choices[popup.indexOfSelectedItem]
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a Template"
            panel.allowedContentTypes = [UTType(exportedAs: IssueTemplate.typeIdentifier)]
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            choice = TemplateChoice(name: url.deletingPathExtension().lastPathComponent, url: url)
            choices.append(choice)
        }
        do {
            let t = try loadTemplate(choice)
            noteTemplateUsed(choice)
            return t
        } catch {
            fileAlert("Couldn't read the template “\(choice.name)”", error.localizedDescription)
            return nil
        }
    }

    /// File › New Template.
    func newTemplateCommand() {
        do {
            try newTemplate(saveTo: {
                askWhereToSave(title: "Save “\(documentTitle)”", message: "What you're working on is saved before the new template starts.")
            })
        } catch let m as MissingPictures {
            if confirmDropping(m) { _ = try? newTemplate(dropMissing: true, saveTo: { nil }) }
        } catch {
            fileAlert("Couldn't save, so no new template was started", error.localizedDescription)
        }
    }

    /// File › Save as Template…
    func saveAsTemplateCommand() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: IssueTemplate.typeIdentifier)]
        panel.title = "Save as Template"
        panel.message = "The pages and their components are kept; the stories and what fills the frames are left out."
        panel.nameFieldStringValue = "\(issue.publication).\(IssueTemplate.fileExtension)"
        if let url = fileURL { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saveAsTemplate(to: url) } catch { fileAlert("Couldn't save the template", error.localizedDescription) }
    }
}
