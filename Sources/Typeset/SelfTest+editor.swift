import AppKit

/// Phase 6 (the component editor) checks, driven through the editor's hit test and pointer state machine at page
/// points, as SelfTest+canvas drives the pages: building a component with each tool; the six pointer rules on the
/// editor's canvas (overlapping elements, an ellipse's and a line's hit areas, zoom, the component's own edge
/// snapping to the page's margins, columns and edge, a lost mouse-up); Save making a new version, the history,
/// opening an old version as the base of the next; the .typesetcomponent round trip; importing a component file
/// and placing it in an issue that then stands without the file. Uses a library of its own; the issue is put back.
extension SelfTest {
    @MainActor
    static func editorChecks(_ store: IssueStore, data: URL, _ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report("editor: " + name, ok, detail) }
        let fm = FileManager.default
        let dir = data.appendingPathComponent("editor-test", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        ComponentFiles.testLibrary = Library(folder: dir)
        defer { ComponentFiles.testLibrary = nil; ComponentEditorWindows.shared.closeAll() }

        // undo as the app has it, one group per gesture or command: the self-test runs in one turn of the run loop
        let e = ComponentEditor.newComponent(pageColumns: 3)
        let undo = UndoManager()
        undo.groupsByEvent = false
        e.undoManager = undo
        e.zoom = 1
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        let o = e.origin
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func drag(_ from: CGPoint, _ to: CGPoint, _ mods: IssueStore.PointerModifiers = []) { step {
            e.pointerDown(at: from, modifiers: mods)
            e.pointerMoved(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), modifiers: mods)
            e.pointerMoved(to: to, modifiers: mods)
            e.pointerUp(at: to, modifiers: mods)
        } }
        func click(_ p: CGPoint, _ mods: IssueStore.PointerModifiers = []) { step { e.pointerDown(at: p, modifiers: mods); e.pointerUp(at: p, modifiers: mods) } }
        func box(_ id: UUID?) -> CGRect? { e.element(id)?.box.rect }
        func r(_ x: CGRect?) -> String { x.map { String(format: "%.1f,%.1f %.1fx%.1f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none" }
        func near(_ a: CGRect?, _ b: CGRect, _ eps: CGFloat = 0.01) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
        }
        let png: Data = {
            let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
            return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }()

        // MARK: building with each tool

        e.tool = .frame; e.frameType = .headline; e.frameLink = "A"
        drag(P(300, 20), P(500, 60), [.command])
        let frameID = e.draft.elements.last?.id
        let frameOK: Bool = { if case .frame(let f)? = e.element(frameID) { f.type == .headline && f.link == "A" } else { false } }()
        check("the Frame tool draws a frame of the picked type and link letter", frameOK && near(box(frameID), CGRect(x: 300, y: 20, width: 200, height: 40))
              && e.tool == .select && e.selection == .element(frameID!), r(box(frameID)))

        e.tool = .line
        drag(P(10, 100), P(200, 104), [.shift, .command])
        let lineID = e.draft.elements.last?.id
        let lineOK: Bool = { if case .line(let l)? = e.element(lineID) { l.y1 == 100 && l.y2 == 100 && l.x1 == 10 && l.x2 == 200 } else { false } }()
        check("the Line tool draws a line, ⇧ keeping it level", lineOK, r(box(lineID)))

        e.tool = .rect; e.fillColor = .red
        click(P(400, 110), [.command])
        let rectID = e.draft.elements.last?.id
        let rectOK: Bool = { if case .rect(let s)? = e.element(rectID) { s.fill == .red } else { false } }()
        check("a click with the Rectangle tool puts down a standard one in the fill colour", rectOK && near(box(rectID), CGRect(x: 400, y: 110, width: 100, height: 60)), r(box(rectID)))

        e.tool = .ellipse
        drag(P(560, 100), P(620, 160), [.command])
        let ellipseID = e.draft.elements.last?.id
        let ellipseOK: Bool = { if case .ellipse? = e.element(ellipseID) { true } else { false } }()
        check("the Ellipse tool draws an ellipse", ellipseOK && near(box(ellipseID), CGRect(x: 560, y: 100, width: 60, height: 60)), r(box(ellipseID)))

        e.tool = .text
        click(P(10, 150), [.command])
        let textID = e.draft.elements.last?.id
        let textOK: Bool = { if case .text(let t)? = e.element(textID) { t.text == "Text" } else { false } }()
        check("the Text tool puts down preset text", textOK && near(box(textID), CGRect(x: 10, y: 150, width: 140, height: 18)), r(box(textID)))

        click(P(450, 140))
        step { e.applyFill(.black) }
        let filled: Bool = { if case .rect(let s)? = e.element(rectID) { s.fill == .black } else { false } }()
        check("the fill colour goes on the selected shape", e.selection == .element(rectID!) && filled)

        let artID = step { e.placeArt(data: png, name: "dot.png") }
        let artOK: Bool = { if case .art(let a)? = e.element(artID) { a.data == png } else { false } }()
        check("Place Art embeds an image", artOK && e.selection == .element(artID ?? UUID()))
        let kinds = Set(e.draft.elements.map { el -> String in
            switch el { case .frame: "frame"; case .line: "line"; case .rect: "rect"; case .ellipse: "ellipse"; case .text: "text"; case .art: "art" }
        })
        check("every kind of element made", kinds.count == 6 && e.draft.elements.count == 6, "\(kinds.sorted())")
        undo.undo()
        let afterUndo = e.draft.elements.count
        undo.redo()
        check("each tool's element is one undo step", afterUndo == 5 && e.draft.elements.count == 6, "\(afterUndo)")

        // MARK: rule 1, clicking selects and nothing else does

        e.selection = nil
        click(P(450, 140))
        check("rule 1: a click selects the element under it", e.selection == .element(rectID!))
        e.pointerHover(at: P(100, 100))
        check("rule 1: hovering a line names it but doesn't select it", e.hovered == .element(lineID!) && e.selection == .element(rectID!))
        click(P(300, 180))
        check("rule 1: a click on the component's empty area selects the component", e.selection == .component)
        click(CGPoint(x: 16, y: 600))
        check("rule 1: a click off the component clears the selection", e.selection == nil)
        let beforeDrag = e.draft
        drag(P(410, 120), P(430, 150), [.command])
        check("rule 1: dragging an unselected element selects and moves it", e.selection == .element(rectID!)
              && near(box(rectID), CGRect(x: 420, y: 140, width: 100, height: 60)), r(box(rectID)))
        undo.undo()
        check("rule 5: the drag is one undo step", e.draft == beforeDrag)
        e.selection = nil
        drag(CGPoint(x: 100, y: 700), CGPoint(x: 300, y: 800))
        check("rule 1: a drag from empty page draws a marquee and picks nothing up", e.draft == beforeDrag && e.selection == nil && !e.pointer.isActive)
        let pressed: EditorPointerState.Phase = {
            e.pointerDown(at: P(450, 140)); e.pointerMoved(to: P(452, 141))
            let ph = e.pointer.phase
            e.pointerUp(at: P(452, 141))
            return ph
        }()
        check("rule 5: under the threshold a press stays a click", pressed == .pressed && e.draft == beforeDrag && e.selection == .element(rectID!))

        // MARK: rules 2 and 3, hit areas match what's drawn and topmost wins

        let backID = step { e.add(.rect(ShapeElement(box: Box(x: 540, y: 90, w: 60, h: 60), fill: .black))) }
        step { e.sendToBack(backID) }
        click(P(590, 130))
        check("rule 3: where two elements overlap, the one drawn on top is hit", e.selection == .element(ellipseID!))
        click(P(562, 102))
        check("rule 2: an ellipse's corner, outside its curve, hits what's under it", e.selection == .element(backID))
        let slant = step { e.add(.line(LineElement(from: CGPoint(x: 20, y: 120), to: CGPoint(x: 120, y: 180)))) }
        e.selection = nil
        click(P(70, 150))
        check("rule 2: a line is hit along its length", e.selection == .element(slant))
        click(P(70, 135))
        check("rule 2: a slanting line's box, away from the line, isn't the line", e.selection == .component)
        e.zoom = 0.5
        let atHalf = ComponentEditor.selection(of: e.hit(at: P(70, 147)))
        e.zoom = 3
        let atThree = ComponentEditor.selection(of: e.hit(at: P(70, 147)))
        e.zoom = 1
        check("rule 2: a thin line's reach is in screen points at every zoom", atHalf == .element(slant) && atThree == .component,
              "\(String(describing: atHalf)) \(String(describing: atThree))")

        // MARK: rule 4, edges belong to the selected item

        e.selection = .element(rectID!)
        let rightEdge = e.hit(at: P(503, 140)).edge
        e.zoom = 2
        let inBand = e.hit(at: P(503, 140)).edge, pastBand = e.hit(at: P(506, 140)).edge
        e.zoom = 0.5
        let wideBand = e.hit(at: P(512, 140)).edge
        e.zoom = 1
        check("rule 4: the selected element's edge reaches the same screen distance at every zoom",
              rightEdge == .e && inBand == .e && pastBand == nil && wideBand == .e)
        check("rule 4: an element that isn't selected has no edge", e.hit(at: P(153, 159)).edge == nil)
        let over = step { e.add(.rect(ShapeElement(box: Box(x: 495, y: 115, w: 30, h: 10), fill: .white))) }
        e.selection = .element(rectID!)
        let overHit = e.hit(at: P(498, 120))
        check("rule 4: the edge yields where an element is drawn over it", overHit.edge == nil && ComponentEditor.selection(of: overHit) == .element(over))
        step { e.delete(over) }
        let lineHit = { () -> CanvasHit in e.selection = .element(lineID!); return e.hit(at: P(12, 100)) }()
        check("rule 4: a level line lengthens from its ends only", lineHit.edge == .w && e.hit(at: P(100, 100)).edge == nil)

        // the component's own edges: resize, snapping to the page
        e.selection = .component
        check("rule 4: the selected component's edge reaches past it", e.hit(at: P(729 + 4, 100)).edge == .e)
        let rectOnPage = e.pageRect(e.element(rectID)!)
        drag(P(300, 203), P(300, 250))
        check("the component's bottom edge pulls", abs(e.draft.height - 247) < 0.01 && e.origin == o, "\(e.draft.height)")
        drag(P(731, 100), P(731 - 245, 100))           // right edge to page x 520: the page's second column ends at 518
        let twoColumns = Grid(columns: 3).span(2)
        check("the component's right edge snaps to a page column", abs(e.draft.width - twoColumns) < 0.01, "\(e.draft.width)")
        drag(P(-2, 100), CGPoint(x: 3, y: 100 + o.y))
        check("its left edge snaps to the page's edge, and the elements stay where they were on the page",
              e.origin.x == 0 && abs(e.draft.width - (twoColumns + HouseStyle.margin)) < 0.01 && near(e.pageRect(e.element(rectID)!), rectOnPage),
              "origin \(e.origin.x) width \(e.draft.width)")
        drag(CGPoint(x: e.rect.maxX + 2, y: 100 + o.y), CGPoint(x: HouseStyle.margin + HouseStyle.liveWidth - 6, y: 100 + o.y))
        check("its right edge snaps to the page's margin", abs(e.rect.maxX - (HouseStyle.margin + HouseStyle.liveWidth)) < 0.01, "\(e.rect.maxX)")
        undo.undo(); undo.undo(); undo.undo(); undo.undo()
        check("each resize of the component is one undo step", e.draft.width == HouseStyle.liveWidth && e.draft.height == 200 && e.origin == o,
              "\(e.draft.width)×\(e.draft.height) at \(e.origin)")

        // MARK: rule 5, one drag model

        e.selection = nil
        let start = box(rectID)!
        drag(P(450, 140), P(480, 145), [.shift, .command])
        check("rule 5: ⇧ holds a drag to one axis", near(box(rectID), start.offsetBy(dx: 30, dy: 0)), r(box(rectID)))
        undo.undo()
        // the rect's left edge, dragged to 3 points short of the component's second column, lands on it
        let column2 = e.columnRects[1].minX - o.x
        drag(P(450, 140), P(450 + (column2 - 3 - 400), 140))
        let snappedX = box(rectID)?.minX
        check("rule 5: an element snaps to the component's own columns, with a guide", snappedX.map { abs($0 - column2) < 0.01 } == true, "\(String(describing: snappedX))")
        undo.undo()
        drag(P(450, 140), P(450 + (column2 - 3 - 400), 140), [.command])
        check("rule 5: ⌘ turns snapping off", box(rectID).map { abs($0.minX - (column2 - 3)) < 0.01 } == true, r(box(rectID)))
        undo.undo()
        e.selection = .element(rectID!)
        drag(P(500 + 2, 140), P(560, 140), [.command])
        check("rule 5: the selected element's edge resizes it", near(box(rectID), CGRect(x: 400, y: 110, width: 158, height: 60)), r(box(rectID)))
        undo.undo()

        // MARK: rule 6, a lost drag cleans up

        let lostBefore = e.draft
        step {
            e.pointerDown(at: P(450, 140), modifiers: [.command])
            e.pointerMoved(to: P(470, 160), modifiers: [.command])
            e.pointerMoved(to: P(490, 180), modifiers: [.command])
            e.pointerCancelled()
        }
        check("rule 6: a lost mouse-up leaves the element where it was dropped",
              near(box(rectID), start.offsetBy(dx: 40, dy: 40)) && !e.pointer.isActive && !e.editingNow && e.guides.isEmpty, r(box(rectID)))
        undo.undo()
        check("rule 6: and that drag is one undo step", e.draft == lostBefore)
        step {
            e.pointerDown(at: P(450, 140), modifiers: [.command])
            e.pointerMoved(to: P(460, 140), modifiers: [.command])
            e.pointerDown(at: P(100, 100))                    // the next press, its mouse-up never came
            e.pointerUp(at: P(100, 100))
        }
        check("rule 6: a press while a gesture is open closes it first", !e.pointer.isActive && !e.editingNow
              && near(box(rectID), start.offsetBy(dx: 10, dy: 0)) && e.selection == .element(lineID!))
        undo.undo()
        step {
            e.pointerDown(at: P(450, 140), modifiers: [.command])
            e.pointerMoved(to: P(470, 140), modifiers: [.command])
            e.pointerHoverButtonUp(at: P(470, 140))
        }
        check("rule 6: a plain move after a lost mouse-up ends the drag", !e.pointer.isActive && !e.editingNow && e.hovered != nil)
        undo.undo()

        // MARK: drawing

        let page = e.composedPage()
        let placeholders = page?.ops.filter { if case .placeholder = $0 { true } else { false } }.count ?? -1
        check("the canvas sets the component as the pages do, its empty frame as a placeholder",
              page?.componentFrames.values.first.map { near($0, e.rect) } == true && placeholders == 1, "\(placeholders) placeholders")

        // MARK: versions

        check("a component never saved is unsaved", e.isEdited && e.base == nil && e.versions.isEmpty)
        let v1 = e.saveVersion()
        check("Save makes version 1", v1.number == 1 && e.base == 1 && !e.isEdited && e.versions.count == 1)
        step { _ = e.add(.rect(ShapeElement(box: Box(x: 0, y: 0, w: 20, h: 20), fill: .red))) }
        check("an edit marks it unsaved", e.isEdited)
        let v2 = e.saveVersion()
        check("Save makes a new version each time", v2.number == 2 && e.versions.map(\.number) == [1, 2] && e.versions[0].sameContent(as: v1))
        step { e.openVersion(1) }
        check("opening an old version shows it and makes it the base", e.draft.sameContent(as: v1) && e.base == 1 && !e.isEdited)
        undo.undo()
        check("opening a version can be undone", e.draft.sameContent(as: v2) && e.base == 2)
        step { e.openVersion(1) }
        let marker = step { e.add(.line(LineElement(from: CGPoint(x: 0, y: 190), to: CGPoint(x: 100, y: 190)))) }
        check("an edit to an old version is unsaved, built on it", e.isEdited && e.base == 1)
        let v3 = e.saveVersion()
        check("saving it makes the next version, from the old one", v3.number == 3 && v3.elements.contains { $0.id == marker }
              && v3.elements.count == v1.elements.count + 1 && e.versions.count == 3)

        // MARK: .typesetcomponent files

        step { e.setName("Self-Test Box") }
        let url = dir.appendingPathComponent("Self-Test Box.typesetcomponent")
        let saved = e.save(to: url)
        let back = try? ComponentFiles.read(url)
        let same = back.map { b in b.id == e.id && b.name == "Self-Test Box" && b.versions.map(\.number) == [1, 2, 3, 4]
            && zip(b.versions, e.versions).allSatisfy { $0.sameContent(as: $1) } } ?? false
        check("Save writes the component and its whole history to a file, and it reads back the same",
              saved && same && e.fileURL == url && !e.isEdited, "versions \(back?.versions.map(\.number) ?? [])")
        check("the saved file is in the library", ComponentFiles.libraryFiles().contains { $0.component.id == e.id }
              && ComponentFiles.fileURL(for: e.id)?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        let junk = dir.appendingPathComponent("junk.typesetcomponent")
        try? Data("{ not a component".utf8).write(to: junk)
        check("a file that isn't a component isn't imported", (try? ComponentFiles.importComponent(junk)) == nil
              && !(ComponentFiles.library?.entries.contains { $0.path == junk.standardizedFileURL.path } ?? true))

        // MARK: import into an issue

        let shared = dir.appendingPathComponent("Shared.typesetcomponent")
        var other = e.componentForSaving
        other.id = UUID(); other.name = "Shared Box"
        try? ComponentFiles.write(other, to: shared)
        let imported = try? ComponentFiles.importComponent(shared)
        check("Import Component adds a file to the library and the sidebar", imported?.id == other.id
              && store.componentCatalog().contains { $0.id == other.id && $0.versions.count == 4 })

        let keep = store.issue, keepUndo = store.undoManager
        let su = UndoManager(); su.groupsByEvent = false; store.undoManager = su
        defer { store.issue = keep; store.undoManager = keepUndo; store.canvasSelection = nil }
        let lastPage = (store.issue.layout?.pages.count ?? 1) - 1
        let placed = undoStep(su) { store.placeComponent(other.id, version: 2, on: lastPage) }
        let embedded = store.issue.componentVersions.first { $0.id == other.id }
        check("placing an imported component copies that version into the issue", placed != nil && embedded?.versions.map(\.number) == [2])
        let issueData = try? IssueStore.encoder().encode(store.issue)
        ComponentFiles.testLibrary = Library(folder: dir.appendingPathComponent("empty", isDirectory: true))
        let reread = issueData.flatMap { try? IssueStore.decoder().decode(Issue.self, from: $0) }
        let drawn = reread.flatMap { i -> Bool? in
            guard let p = placed, let pc = i.layout?.pages[lastPage].components.first(where: { $0.id == p }) else { return nil }
            return i.version(of: pc) != nil && store.composer.compose(i)[lastPage].componentFrames[p] != nil
        } ?? false
        check("the issue stands without the component file: it reads back and draws the component", drawn)
        check("without the file, the sidebar marks it in this issue only", store.isInIssueOnly(other.id)
              && store.componentCatalog().first { $0.id == other.id }?.versions.map(\.number) == [2])
        let issueOnly = store.editComponent(other.id)
        check("Edit opens the editor on it, at the version the issue has", issueOnly?.base == 2 && issueOnly?.fileURL == nil
              && ComponentEditorWindows.shared.editors.contains { $0 === issueOnly })
        if let c = store.catalogComponent(other.id) {
            let added = dir.appendingPathComponent("Added.typesetcomponent")
            try? ComponentFiles.save(c, to: added)
            check("Add to Library saves it as a file, and it's no longer in this issue only", !store.isInIssueOnly(other.id)
                  && (try? ComponentFiles.read(added))?.versions.map(\.number) == [2])
        }
    }
}
