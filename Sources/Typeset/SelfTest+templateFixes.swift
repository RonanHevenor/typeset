import AppKit

/// Phase 8 review fixes: the Pages step generates the paper of an issue made from a template; Don't Repeat on New
/// Pages (and removing a component from every page) keeps Add Page from putting it back, in an issue made before
/// templates too; the generator plans the front page's stories around a component placed low on it; an embedded
/// template with a wrong-typed field still reads. Works on stores of its own; the main store's issue is only read.
extension SelfTest {
    @MainActor
    static func templateFixes(_ report: (String, Bool, String) -> Void, store: IssueStore, data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        let fm = FileManager.default
        let dir = data.appendingPathComponent("TemplateFixes", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let Fo = BuiltInComponents.folioID
        let poly = BuiltInTemplates.polytechnic
        let s = IssueStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        s.undoManager = undo
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        func folios(_ p: PageLayout) -> [PlacedComponent] { p.components.filter { $0.component == Fo } }

        // 1. New Issue from The Polytechnic, stories in, then the Pages step: the paper is generated
        do {
            _ = try s.newIssue(dropMissing: true, saveTo: { dir.appendingPathComponent("Before.typeset") }, template: { poly })
            check("template fixes: an issue new from a template, before any stories, has its pages but no paper yet",
                  s.issue.layout?.pages.count == 4 && s.issue.paperNotGenerated == false && s.issue.articles.isEmpty)
            s.issue.articles = store.issue.articles
            check("  with stories in, the paper counts as not generated (the sidebar shows no pages yet)", s.issue.paperNotGenerated)
            step { s.go(to: .pages) }
            let l = s.issue.layout!
            check("  the Pages step generates it: stories placed, not stale, the Header and Folios kept",
                  s.issue.stage == .pages && !s.issue.paperNotGenerated && !s.layoutIsStale && l.pages.contains { !$0.stories.isEmpty }
                  && l.pages[0].components.first?.component == BuiltInComponents.headerID && l.pages.dropFirst().allSatisfy { !folios($0).isEmpty },
                  "\(l.pages.map(\.stories.count))")
            step { s.go(to: .stories) }
            step { s.go(to: .pages) }
            check("  going back to the Pages step keeps that paper (no second generation)", s.issue.layout == l)
        } catch { check("template fixes: New Issue from a template", false, "\(error)") }

        // 2. Don't Repeat on New Pages, and a component removed from every page, stay off new pages
        if let fid = s.issue.layout?.pages.dropFirst().compactMap({ folios($0).first }).first?.id {
            step { s.stopRepeating(fid) }
            let count = s.issue.layout!.pages.count
            step { s.addPage() }
            check("Don't Repeat on New Pages: Add Page leaves the Folio off the new page",
                  s.issue.layout!.pages.count == count + 1 && folios(s.issue.layout!.pages.last!).isEmpty,
                  "\(s.issue.layout!.pages.last!.components.count) components")
            undo.undo(); undo.undo()
            step { s.addPage() }
            check("  undone, the Folio repeats again", folios(s.issue.layout!.pages.last!).count == 1)
            undo.undo()
            s.issue.layout!.pages = s.issue.layout!.pages.map { var p = $0; p.components.removeAll { $0.component == Fo }; return p }
            step { s.addPage() }
            check("  a Folio removed from every page isn't put back by Add Page", folios(s.issue.layout!.pages.last!).isEmpty)
        } else { check("Don't Repeat on New Pages", false, "no Folio placed") }

        // 3. an issue saved before templates (format 2, no repeat marks): its Folio is marked when it's opened
        do {
            var old = Issue()
            old.articles = store.issue.articles
            old.generateLayout(composer: store.composer, seed: 5)
            old.layout!.pages = old.layout!.pages.map { var p = $0; p.components = p.components.map { var c = $0; c.repeats = nil; return c }; return p }
            old.template = nil
            old.format = 2
            let url = dir.appendingPathComponent("old.json")
            try IssueStore.encoder().encode(old).write(to: url)
            let back = IssueStore.load(from: url)
            let marked = back?.layout?.pages.dropFirst().allSatisfy { folios($0).allSatisfy { $0.repeats == .insidePages } && !folios($0).isEmpty } == true
            check("an issue from before templates opens with its Folios marked as repeating inside, in format \(Issue.currentFormat)",
                  marked && back?.format == Issue.currentFormat && back?.layout?.pages[0].components.allSatisfy { $0.repeats == nil } == true)
            if var b = back {
                b.layout!.pages.append(PageLayout())
                b.placeRepeaters(onPage: b.layout!.pages.count - 1)
                check("  Add Page gives it the Folio, as before", folios(b.layout!.pages.last!).count == 1)
                b.layout!.pages = b.layout!.pages.map { var p = $0; p.components = p.components.map { var c = $0; c.repeats = nil; return c }; return p }
                try IssueStore.encoder().encode(b).write(to: url)
                let again = IssueStore.load(from: url)
                check("  unmarked and saved, it opens unmarked (Don't Repeat on New Pages sticks)",
                      again?.layout?.pages.allSatisfy { $0.components.allSatisfy { $0.repeats == nil } } == true)
            }
        } catch { check("an issue from before templates", false, "\(error)") }

        // 4. a component low on the template's front page: the front stories are planned around it
        do {
            typealias F = HouseStyle.Front
            var t = poly
            let box = Box(x: HouseStyle.margin, y: F.leadTop + 120, w: HouseStyle.liveWidth, h: 80)
            let v = ComponentVersion(number: 1, width: box.w, height: box.h, elements: [.frame(Frame(type: .ad, box: Box(x: 0, y: 0, w: box.w, h: box.h)))],
                                     date: Date(timeIntervalSince1970: 1_793_664_000))
            let card = Component(name: "Front Card", versions: [v])
            t.pages[0].components.append(PlacedComponent(component: card.id, version: 1, frame: box))
            t.componentVersions.append(card)
            var i = Issue()
            i.articles = store.issue.articles
            i.start(from: t)
            i.generateLayout(composer: store.composer, seed: 11)
            let front = i.layout!.pages[0]
            let r = Composer.wrap(box.rect)
            let onIt = front.insets.filter { $0.frame.rect.intersects(r) }
            check("the generator plans the front stories around a component low on the template's front page: no picture on it",
                  front.components.contains { $0.component == card.id } && !front.stories.isEmpty && onIt.isEmpty, "\(onIt.count) on it")
            var j = Issue()
            j.articles = store.issue.articles
            j.start(from: poly)
            j.generateLayout(composer: store.composer, seed: 11)
            check("  (the premise: without the component, a front picture lands where it sits)",
                  j.layout!.pages[0].insets.contains { $0.kind == .photo && $0.frame.rect.intersects(r) })
        }

        // 5. an embedded template with a wrong-typed name or format still reads, with its pages
        do {
            var i = Issue()
            var t = poly
            t.name = "Kept"
            i.start(from: t)
            var json = try JSONSerialization.jsonObject(with: IssueStore.encoder().encode(i)) as! [String: Any]
            var tj = json["template"] as! [String: Any]
            tj["format"] = "one"; tj["name"] = 5
            json["template"] = tj
            let back = try IssueStore.decoder().decode(Issue.self, from: JSONSerialization.data(withJSONObject: json))
            check("an issue whose embedded template has a wrong-typed name and format keeps the template's pages",
                  back.template != nil && back.template?.pages.count == 4 && back.template?.repeaters.first?.component == Fo,
                  back.template?.name ?? "nil")
        } catch { check("an embedded template with wrong-typed fields", false, "\(error)") }
    }
}
