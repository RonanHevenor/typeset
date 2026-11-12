import AppKit

/// Phase 8 (templates): the shipped template, a template's file (round trip, lenient reading), Save as Template,
/// New Issue from a template and the last one used, the generator laying stories out around a template's
/// components, Duplicate on All (Inside) Pages with Add Page, and the template editor: its pages (add, move,
/// remove) and the pointer on its canvas, through the same hit test and state machine as the issue's pages.
/// Works on stores of its own; the main store's issue is only read.
extension SelfTest {
    @MainActor
    static func templates(_ report: (String, Bool, String) -> Void, store: IssueStore, data: URL) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        let fm = FileManager.default
        let dir = data.appendingPathComponent("Templates", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: IssueStore.lastTemplateURL)
        let H = BuiltInComponents.headerID, Fo = BuiltInComponents.folioID

        /// A page as the generator leaves it, without the ids that are new every time.
        func shape(_ l: IssueLayout?) -> [String] {
            (l?.pages ?? []).map { p in
                let s = p.stories.map { "S\($0.article)\($0.frame)\($0.columns)\($0.headlineSize)" }
                let i = p.insets.map { "I\($0.kind)\(String(describing: $0.article))\(String(describing: $0.photo))\($0.frame)" }
                let c = p.components.map { "C\($0.component)v\($0.version)\($0.frame)" }
                return "\(p.isFront)|" + (s + i + c).joined(separator: ";")
            }
        }
        func comps(_ p: PageLayout) -> [Component.ID] { p.components.map(\.component) }

        // 1. the shipped template, and an issue made from it laid out as before
        let poly = BuiltInTemplates.polytechnic
        check("templates: The Polytechnic ships with the Header on page 1 and the Folio on the rest, repeating inside",
              poly.pages.count == 4 && comps(poly.pages[0]) == [H] && poly.pages.dropFirst().allSatisfy { comps($0) == [Fo] && $0.components[0].repeats == .insidePages }
              && poly.pages[0].components[0].repeats == nil && Set(poly.componentVersions.map(\.id)) == [H, Fo] && poly.keptPageCount == 1,
              "\(poly.pages.map { $0.components.count })")
        var before = Issue(), from = Issue()
        before.articles = store.issue.articles; before.extras = store.issue.extras
        from.articles = store.issue.articles; from.extras = store.issue.extras
        from.start(from: poly)
        before.generateLayout(composer: store.composer, seed: 7)
        from.generateLayout(composer: store.composer, seed: 7)
        check("templates: an issue made from The Polytechnic lays out exactly as one made before templates",
              shape(before.layout) == shape(from.layout) && before.layout!.pages.count > 1, "\(before.layout?.pages.count ?? 0) vs \(from.layout?.pages.count ?? 0) pages")
        check("  the Header on the front, the Folio on every inside page, both copied into the issue",
              comps(from.layout!.pages[0]) == [H] && from.layout!.pages.dropFirst().allSatisfy { comps($0) == [Fo] }
              && from.layout!.pages[0].components[0].frame.rect.origin == BuiltInComponents.headerOrigin
              && Set(from.componentVersions.map(\.id)) == [H, Fo])

        // a test card to place: a frame and a rule
        let rule = LineElement(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 240, y: 0))
        let cardV = ComponentVersion(number: 1, width: 240, height: 120, elements: [.line(rule), .frame(Frame(type: .ad, box: Box(x: 0, y: 4, w: 240, h: 116)))],
                                     date: Date(timeIntervalSince1970: 1_793_664_000))     // whole seconds: the file keeps ISO 8601 dates
        let card = Component(name: "Template Card", versions: [cardV])

        // 2. Save as Template: pages and components, no stories, no fills; and the file's round trip
        do {
            var issue = from
            if let a = issue.articles.first(where: { !$0.photos.isEmpty }) { issue.fillHeader(with: Array(issue.articles.prefix(3)), photo: (a, a.photos[0])) }
            issue.embed(card, version: 1)
            issue.place(card, version: 1, on: 1, at: CGPoint(x: 100, y: 500), fills: [Fill(frame: cardV.frames[0].id, extra: issue.extras.first?.id)])
            let t = IssueTemplate(issue: issue, name: "Saved")
            check("Save as Template keeps the pages and their components",
                  t.pages.count == issue.layout!.pages.count && zip(t.pages, issue.layout!.pages).allSatisfy { comps($0) == comps($1) && $0.components.map(\.frame) == $1.components.map(\.frame) })
            check("  and drops the stories, pictures and what fills the frames",
                  t.pages.allSatisfy { $0.stories.isEmpty && $0.insets.isEmpty && $0.components.allSatisfy(\.fills.isEmpty) }
                  && issue.layout!.pages.contains { !$0.stories.isEmpty } && issue.layout!.pages[0].components[0].fills.count > 0)
            check("  carrying only the component versions its pages use", Set(t.componentVersions.map(\.id)) == [H, Fo, card.id])
            let url = dir.appendingPathComponent("Saved.\(IssueTemplate.fileExtension)")
            try t.write(to: url)
            let back = try IssueTemplate.read(url)
            check("template round trip: written and read back, the same template", back == t, "\(back.pages.count) pages")

            // lenient: an unreadable placement, element and version are dropped on their own
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var pages = json["pages"] as! [[String: Any]]
            var cs = pages[1]["components"] as! [[String: Any]]
            cs.append(["version": 1])                                        // no component, no frame
            pages[1]["components"] = cs
            pages.append(["isFront": "not a bool", "components": [["component": card.id.uuidString, "frame": ["x": 1, "y": 2, "w": 3, "h": 4], "repeats": "everywhere"]]])
            json["pages"] = pages
            var versions = json["componentVersions"] as! [[String: Any]]
            let k = versions.firstIndex { ($0["id"] as? String) == card.id.uuidString }!
            var vs = versions[k]["versions"] as! [[String: Any]]
            var els = vs[0]["elements"] as! [[String: Any]]
            els.append(["kind": "hologram"])
            vs[0]["elements"] = els
            vs.append(["number": 2])                                         // no size
            versions[k]["versions"] = vs
            versions.append(["name": "no id"])
            json["componentVersions"] = versions
            json["something"] = "from a newer Typeset"
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            let lenient = try? IssueTemplate.read(url)
            check("a template file with an unreadable placement, element, version and component still opens",
                  lenient != nil && lenient!.pages.count == t.pages.count + 1 && lenient!.pages[1].components.count == t.pages[1].components.count
                  && lenient!.pages.last!.components.first?.repeats == nil && !lenient!.pages.last!.isFront
                  && lenient!.componentVersions.count == t.componentVersions.count
                  && lenient!.componentVersions.first { $0.id == card.id }?.versions.map { $0.elements.count } == [2],
                  "\(lenient?.pages.count ?? -1) pages, \(lenient?.componentVersions.count ?? -1) components")
        } catch { check("template round trip", false, "\(error)") }

        // 3. Save as Template… from the store: a file in the library, with page 1's picture
        do {
            let url = dir.appendingPathComponent("From Store.\(IssueTemplate.fileExtension)")
            try store.saveAsTemplate(to: url)
            let e = Library.shared.entries(.template).first { $0.path == url.standardizedFileURL.path }
            check("Save as Template… writes the file and puts it in the library's Templates with a thumbnail",
                  fm.fileExists(atPath: url.path) && e != nil && e.flatMap { Library.shared.thumbnailImage($0) } != nil && !store.isEditingTemplate)
        } catch { check("Save as Template… writes the file", false, "\(error)") }

        // 4. New Issue from a template: its pages, its components, issue fields filled; then stories around them
        let s = IssueStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        s.undoManager = undo
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        var custom = IssueTemplate(name: "Three", pages: Array(poly.pages.prefix(2)) + [PageLayout()], componentVersions: poly.componentVersions)
        custom.pages[2].components = [PlacedComponent(component: card.id, version: 1, frame: Box(x: HouseStyle.margin, y: 560, w: 240, h: 120))]
        custom.componentVersions.append(card)
        let customURL = dir.appendingPathComponent("Three.\(IssueTemplate.fileExtension)")
        try? custom.write(to: customURL)
        Library.shared.note(customURL, kind: .template)
        do {
            s.issue.volume = "CXLV"; s.issue.edition = "IX"
            s.saveNow()
            let started = try s.newIssue(dropMissing: true, saveTo: { dir.appendingPathComponent("Before.typeset") }, template: { custom })
            let l = s.issue.layout
            check("New Issue from a template starts with its pages and components, no stories",
                  started && l?.pages.count == 3 && l.map { zip($0.pages, custom.pages).allSatisfy { comps($0) == comps($1) && $0.components.map(\.frame) == $1.components.map(\.frame) } } == true
                  && s.issue.articles.isEmpty && l?.pages.allSatisfy { $0.stories.isEmpty } == true && l?.pages[0].isFront == true && s.issue.template?.name == "Three",
                  "\(l?.pages.map { $0.components.count } ?? [])")
            check("  with every version it uses copied into the issue", s.issue.layout!.pages.flatMap(\.components).allSatisfy { s.issue.version(of: $0) != nil })
            check("  the next edition, Untitled, and blank (New Issue again doesn't save it)",
                  s.issue.edition == "X" && s.issue.volume == "CXLV" && s.fileURL == nil && s.isBlank && !s.needsSave, "Ed. \(s.issue.edition)")
            let folio = s.issue.layout!.pages[1].components[0]
            let number = s.issue.version(of: folio)?.frames.first { $0.type == .pageNumber }
            let dateline = s.issue.version(of: s.issue.layout!.pages[0].components[0])?.frames.first { $0.type == .date }
            let pageText = number.map { Composer.fieldText($0, issue: s.issue, number: 2, section: "") }
            let dateText = dateline.map { Composer.fieldText($0, issue: s.issue, number: 1, section: "") }
            check("  issue fields filled: the Folio's page number, the Header's dateline with the new edition",
                  pageText == "2" && dateText?.contains("Vol. CXLV Ed. X") == true, "\(pageText ?? "-") / \(dateText ?? "-")")

            // the stories go in, the paper is generated around the template's components
            s.issue.articles = store.issue.articles
            step { s.generate() }
            let g = s.issue.layout!
            let cardPage = g.pages.firstIndex { $0.components.contains { $0.component == card.id } }
            check("generating keeps the template's pages: Header on the front, its card on page 3, the Folio inside",
                  comps(g.pages[0]) == [H] && g.pages.dropFirst().allSatisfy { comps($0).contains(Fo) || comps($0) == [card.id] }
                  && cardPage == 2 && g.pages.count >= 3, "\(g.pages.map { comps($0).count }) card on \(cardPage.map { $0 + 1 } ?? 0)")
            if let c = cardPage {
                let r = g.pages[c].components.first { $0.component == card.id }!.frame.rect
                let pics = g.pages[c].insets.filter { $0.kind == .photo && $0.frame.rect.intersects(r) }
                check("  and plans the stories' pictures around the card", pics.isEmpty, "\(pics.count) on it")
            }
            undo.removeAllActions()
            step { s.addPage() }
            check("Add Page on an issue from a template gives the new page its repeating Folio, not its card",
                  comps(s.issue.layout!.pages.last!) == [Fo])
        } catch { check("New Issue from a template", false, "\(error)") }

        // 5. the last template used is the one New Issue offers
        do {
            let choices = s.templateChoices()
            let three = choices.first { $0.name == "Three" && $0.url != nil }
            check("New Issue offers The Polytechnic first, then the library's templates", choices.first == .shipped && three != nil, choices.map(\.name).joined(separator: ", "))
            check("  The Polytechnic is selected when nothing has been used yet", s.lastTemplateChoice(in: choices) == .shipped)
            if let three { s.noteTemplateUsed(three) }
            check("  the last one used is selected", s.lastTemplateChoice(in: s.templateChoices()) == three, s.lastTemplateChoice(in: s.templateChoices()).name)
            check("  and it reads", (try? s.loadTemplate(three ?? .shipped))?.pages.count == 3)
            s.noteTemplateUsed(.shipped)
            check("  back to The Polytechnic when that was last", s.lastTemplateChoice(in: s.templateChoices()) == .shipped)
            if let three { s.noteTemplateUsed(three) }
            try? fm.moveItem(at: customURL, to: dir.appendingPathComponent("gone.json"))
            check("  and to The Polytechnic when the last one's file is gone", s.lastTemplateChoice(in: s.templateChoices()) == .shipped)
            try? fm.moveItem(at: dir.appendingPathComponent("gone.json"), to: customURL)
        }

        // 6. the template editor: New Template, its pages, the pointer on its canvas, Duplicate on All Pages
        let t = IssueStore()
        let tu = UndoManager()
        tu.groupsByEvent = false
        t.undoManager = tu
        t.zoom = 1
        func tstep<T>(_ f: () -> T) -> T { undoStep(tu, f) }
        func fresh() { tstep { t.pointerCancelled() }; tu.removeAllActions(); t.canvasSelection = nil }
        func drag(_ from: CGPoint, by d: CGSize, on page: Int, to target: IssueStore.PointerLocation? = nil, mods: IssueStore.PointerModifiers = []) {
            tstep {
                t.pointerDown(at: from, on: page, modifiers: mods)
                t.pointerMoved(to: .page(page, CGPoint(x: from.x + d.width / 2, y: from.y + d.height / 2)), modifiers: mods)
                let to = target ?? .page(page, CGPoint(x: from.x + d.width, y: from.y + d.height))
                t.pointerMoved(to: to, modifiers: mods)
                t.pointerUp(at: to, modifiers: mods)
            }
        }
        do {
            _ = try t.newTemplate(dropMissing: true, saveTo: { dir.appendingPathComponent("Before template.typeset") })
            let l = t.issue.layout!
            check("New Template opens the template editor on The Polytechnic: four pages, Header, Folios, no stories",
                  t.isEditingTemplate && l.pages.count == 4 && comps(l.pages[0]) == [H] && l.pages.dropFirst().allSatisfy { comps($0) == [Fo] }
                  && t.issue.articles.isEmpty && t.issue.stage == .pages && t.documentTitle == "Untitled Template")
            let pagesBefore = t.issue.layout
            t.generate(); t.clearPages()
            check("  Shuffle and Clear Pages leave a template alone", t.issue.layout == pagesBefore)
        } catch { check("New Template opens the template editor", false, "\(error)") }

        t.issue.embed(card, version: 1)                       // in the catalogue, as a library component would be
        fresh()
        let at = CGPoint(x: 120, y: 400)
        let placedOK = tstep { t.place(.component(card.id, 1), on: 1, at: at) }
        guard placedOK, let placed = t.issue.layout?.pages[1].components.last, placed.component == card.id else {
            check("template editor: dropping a component row on a page places it", false); return
        }
        let id = placed.id
        func frame() -> CGRect? { t.placedComponent(id)?.placed.frame.rect }
        let f0 = placed.frame.rect
        check("template editor: dropping a component row on a page places it, selected, one undo step",
              t.canvasSelection == .component(id) && tu.canUndo)
        let mid = CGPoint(x: f0.midX, y: f0.midY)
        fresh()
        check("  rule 3: right-click, hover and click agree on what's under the pointer: the component", t.hit(at: mid, on: 1).what == .component(id))
        t.pointerHover(at: mid, on: 1)
        check("  rule 1: hovering doesn't select", t.canvasSelection == nil)
        drag(mid, by: .zero, on: 1)
        check("  rule 1: a click selects it", t.canvasSelection == .component(id))
        drag(CGPoint(x: f0.maxX + 60, y: f0.maxY + 60), by: .zero, on: 1)
        check("  a click on empty paper clears the selection", t.canvasSelection == nil)
        fresh()
        drag(mid, by: CGSize(width: 30, height: 40), on: 1, mods: [.command])
        check("  rule 5: dragging it unselected selects and moves it, one undo step",
              frame().map { abs($0.minX - f0.minX - 30) < 0.01 && abs($0.minY - f0.minY - 40) < 0.01 } == true && t.canvasSelection == .component(id))
        tu.undo()
        check("  undo puts it back", frame() == f0 && !tu.canUndo)
        fresh()
        drag(mid, by: CGSize(width: 10, height: 10), on: 1, to: .page(2, CGPoint(x: mid.x + 10, y: mid.y + 10)), mods: [.command])
        check("  dragged onto another page, it goes there", t.placedComponent(id)?.page == 2)
        tu.undo()
        fresh()
        drag(mid, by: CGSize(width: 10, height: 10), on: 1, to: .inspector)
        check("  dragged off the canvas into the sidebar, it comes off the page; undo brings it back",
              t.placedComponent(id) == nil && { tu.undo(); return t.placedComponent(id)?.page == 1 }())
        fresh()
        tstep {
            t.pointerDown(at: mid, on: 1, modifiers: [.command])
            t.pointerMoved(to: .page(1, CGPoint(x: mid.x + 20, y: mid.y)), modifiers: [.command])
            t.pointerCancelled()
        }
        check("  rule 6: a lost mouse-up leaves it where it was dropped, nothing mid-drag",
              frame().map { abs($0.minX - f0.minX - 20) < 0.01 } == true && !t.pointer.isActive && t.dragging == nil)
        tu.undo()

        // Duplicate on All (Inside) Pages, and Add Page
        fresh()
        let n = t.issue.layout!.pages.count
        tstep { t.duplicateOnAllPages(id, inside: true) }
        var pages = t.issue.layout!.pages
        check("Duplicate on All Inside Pages puts it on every inside page, not the front, all marked to repeat inside",
              !comps(pages[0]).contains(card.id) && pages.dropFirst().allSatisfy { p in p.components.filter { $0.component == card.id }.count == 1 }
              && pages.flatMap(\.components).filter { $0.component == card.id }.allSatisfy { $0.repeats == .insidePages && $0.frame.rect == f0 && $0.fills.isEmpty })
        tu.undo()
        check("  one undo step takes the copies off", t.issue.layout!.pages.flatMap(\.components).filter { $0.component == card.id }.count == 1
              && t.placedComponent(id)?.placed.repeats == nil)
        tu.redo()
        tstep { t.addPage() }
        pages = t.issue.layout!.pages
        check("  Add Page puts it on the new page too, with the Folio", pages.count == n + 1 && Set(comps(pages[n])) == [Fo, card.id])
        tstep { t.duplicateOnAllPages(id, inside: false) }
        tstep { t.addPage(after: 0) }
        pages = t.issue.layout!.pages
        check("Duplicate on All Pages adds the front page, and Add Page keeps putting it on",
              comps(pages[0]).contains(card.id) && comps(pages[1]).contains(card.id) && pages.flatMap(\.components).filter { $0.component == card.id }.allSatisfy { $0.repeats == .allPages })
        tstep { t.stopRepeating(id) }
        tstep { t.addPage() }
        check("  Don't Repeat on New Pages: the next page added doesn't get it", !comps(t.issue.layout!.pages.last!).contains(card.id)
              && comps(t.issue.layout!.pages.last!).contains(Fo))

        // pages: move and remove; the first page is the front
        let count = t.issue.layout!.pages.count
        let second = t.issue.layout!.pages[1].id, first = t.issue.layout!.pages[0].id
        tstep { t.movePage(1, to: 0) }
        check("template editor: moving a page to the top makes it the front", t.issue.layout!.pages[0].id == second && t.issue.layout!.pages[0].isFront
              && t.issue.layout!.pages[1].id == first && !t.issue.layout!.pages[1].isFront)
        tu.undo()
        tstep { t.removeTemplatePage(0) }
        check("  removing the front page makes the next one the front", t.issue.layout!.pages.count == count - 1 && t.issue.layout!.pages[0].id == second && t.issue.layout!.pages[0].isFront)
        tu.undo()
        check("  and undo puts it back", t.issue.layout!.pages[0].id == first && t.issue.layout!.pages.count == count)

        // Save, reopen, and a new issue from it
        do {
            let url = dir.appendingPathComponent("Edited.\(IssueTemplate.fileExtension)")
            try t.save(to: url)
            check("Save in the template editor writes a template file, in the library's Templates",
                  (try? IssueTemplate.read(url))?.pages.count == count && t.fileURL == url && !t.isEdited && t.documentTitle == "Edited"
                  && Library.shared.entries(.template).contains { $0.path == url.standardizedFileURL.path })
            let o = IssueStore()
            try o.open(url)
            check("  opening it gives the template editor the same pages and components", o.isEditingTemplate
                  && o.issue.layout!.pages.map(comps) == t.issue.layout!.pages.map(comps)
                  && o.issue.layout!.pages.flatMap(\.components).map(\.repeats) == t.issue.layout!.pages.flatMap(\.components).map(\.repeats))
            let relaunched = IssueStore()
            check("  a relaunch comes back to the template editor", relaunched.isEditingTemplate && relaunched.fileURL == url)
            t.issue.layout!.pages[0].components.removeAll()
            t.saveNow()
            let edition = t.issue.edition
            let made = try t.newIssue(saveTo: { nil }, template: { try? IssueTemplate.read(url) })
            check("New Issue from the template editor saves the template first, then starts the issue from it",
                  made && !t.isEditingTemplate && (try? IssueTemplate.read(url))?.pages[0].components.isEmpty == true
                  && t.issue.layout?.pages.count == count && t.issue.edition == IssueStore.nextEdition(after: edition))
        } catch { check("Save in the template editor", false, "\(error)") }
        try? fm.removeItem(at: IssueStore.lastTemplateURL)
    }
}
