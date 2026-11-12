import AppKit

/// Phase 6 review fixes, each through the editor's own pointer and commands: a line's resize passing through no
/// width, a width typed for an upright line, a ⇧-drawn line beside a snap line, snapping that would shrink below
/// the smallest size, a gutter too wide for the columns, Edit… on another version of an open component, the
/// editor's page (no EMPTY marks, one cached page), and art hashed by sample.
extension SelfTest {
    @MainActor
    static func editorFixChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report("editor fixes: " + name, ok, detail) }
        let e = ComponentEditor.newComponent(pageColumns: 3)
        let undo = UndoManager()
        undo.groupsByEvent = false
        e.undoManager = undo
        e.zoom = 1
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        let o = e.origin
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func line(_ id: UUID) -> LineElement? { if case .line(let l)? = e.element(id) { l } else { nil } }
        func ends(_ l: LineElement?) -> String { l.map { String(format: "%.1f,%.1f → %.1f,%.1f", $0.x1, $0.y1, $0.x2, $0.y2) } ?? "none" }

        // 1. a line's end pulled past its other end and back: it's rebuilt from where the gesture began
        let diag = step { e.add(.line(LineElement(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60)))) }
        e.selection = .element(diag)
        step {
            e.pointerDown(at: P(110, 60), modifiers: [.command])
            e.pointerMoved(to: P(-20, 60), modifiers: [.command])      // past the far end: no width for a moment
            e.pointerMoved(to: P(160, 80), modifiers: [.command])
            e.pointerUp(at: P(160, 80), modifiers: [.command])
        }
        let l1 = line(diag)
        check("a line's end dragged past its other end and back keeps its slope", l1.map {
            abs($0.x1 - 10) < 0.01 && abs($0.y1 - 10) < 0.01 && abs($0.x2 - 160) < 0.01 && abs($0.y2 - 80) < 0.01 } ?? false, ends(l1))
        undo.undo()
        check("…and it's one undo step", line(diag).map { $0.x2 == 110 && $0.y2 == 60 } ?? false, ends(line(diag)))

        // 2. an upright line given a width in the inspector: its second end moves out
        let upright = step { e.add(.line(LineElement(from: CGPoint(x: 200, y: 20), to: CGPoint(x: 200, y: 120)))) }
        step { e.update(upright, "Resize") { $0.box.w = 50 } }
        let l2 = line(upright)
        check("W typed for an upright line gives it that width", l2.map { $0.x1 == 200 && $0.x2 == 250 && $0.y1 == 20 && $0.y2 == 120 } ?? false, ends(l2))
        let level = step { e.add(.line(LineElement(from: CGPoint(x: 10, y: 150), to: CGPoint(x: 90, y: 150)))) }
        step { e.update(level, "Resize") { $0.box.h = 30 } }
        check("H typed for a level line gives it that height", line(level).map { $0.y1 == 150 && $0.y2 == 180 } ?? false, ends(line(level)))

        // 3. ⇧ holds a new line level even with an edge a few points off its axis
        let rule = step { e.add(.rect(ShapeElement(box: Box(x: 300, y: 103, w: 60, h: 20), fill: .red))) }
        e.selection = nil
        e.tool = .line
        step {
            e.pointerDown(at: P(20, 100), modifiers: [.shift])
            e.pointerMoved(to: P(120, 102), modifiers: [.shift])
            e.pointerMoved(to: P(250, 104), modifiers: [.shift])
            e.pointerUp(at: P(250, 104), modifiers: [.shift])
        }
        let drawn = e.draft.elements.last.flatMap { el -> LineElement? in if case .line(let l) = el { l } else { nil } }
        check("a ⇧-drawn line stays level with a snap edge 3 pt off it", drawn.map { $0.y1 == 100 && $0.y2 == 100 } ?? false, ends(drawn))
        step { e.delete(rule) }

        // 4. snapping never pulls an edge in past the smallest size
        let small = step { e.add(.rect(ShapeElement(box: Box(x: 100, y: 20, w: 30, h: 30), fill: .red))) }
        _ = step { e.add(.rect(ShapeElement(box: Box(x: 101, y: 200, w: 50, h: 20), fill: .red))) }
        e.selection = .element(small)
        let zone = e.hit(at: P(130, 35)).edge
        step {
            e.pointerDown(at: P(130, 35))
            e.pointerMoved(to: P(110, 35))
            e.pointerMoved(to: P(90, 35))
            e.pointerUp(at: P(90, 35))
        }
        let w = e.element(small)?.box.w ?? 0
        check("an element's right edge snapped near its left keeps 4 pt", zone != nil && w >= ComponentEditor.minElementSize.width - 0.01,
              "edge \(zone.map { "\($0)" } ?? "none"), width \(w)")

        // 5. a gutter too wide for the columns is cut to leave each column 12 pt, in the editor and on the page
        step { e.setColumns(3) }
        step { e.setGutter(300) }
        let cols = e.columnRects
        check("a 300 pt gutter on a live-width, 3-column component leaves columns of at least 12 pt",
              (e.draft.gutter ?? 0) <= (e.draft.width - 36) / 2 + 0.01 && cols.allSatisfy { $0.width >= ComponentVersion.minColumn - 0.01 },
              "gutter \(e.draft.gutter ?? -1), columns \(cols.map(\.width))")
        var issue = Issue()
        let wide = Component(name: "Wide Gutter", versions: [ComponentVersion(number: 1, width: 468, height: 100, columns: 3, gutter: 300)])
        issue.componentVersions = [wide]
        let placed = PlacedComponent(component: wide.id, version: 1, frame: Box(x: 36, y: 100, w: 468, h: 100))
        let rc = ResolvedComponent(placed, in: issue, pageColumns: 3)
        check("a file's 300 pt gutter reaches the page as columns of at least 12 pt", rc.map {
            $0.columnRects.allSatisfy { $0.width >= ComponentVersion.minColumn - 0.01 } } ?? false,
              rc.map { "\($0.columnRects.map(\.width))" } ?? "none")
        check("a gutter is never more than a narrow frame's columns allow", ComponentVersion.clampedGutter(12, width: 30, columns: 3) == 0
              && ComponentVersion.clampedGutter(12, width: 468, columns: 3) == 12 && ComponentVersion.clampedGutter(-5, width: 468, columns: 1) == 0)

        // 6. the editor's page: no EMPTY marks for the rest of it, and the same page from the cache each redraw
        let a = e.composedPage(), b = e.composedPage()
        check("the editor's page has no EMPTY marks, and a redraw with nothing changed reuses it",
              a != nil && a?.holes.isEmpty == true && a === b, "holes \(a?.holes.count ?? -1)")

        // 7. art hashed by sample: a big embedded picture hashes fast, and equal art hashes equal
        let big = Data(repeating: 7, count: 20_000_000)
        let art = ArtElement(box: Box(x: 0, y: 0, w: 10, h: 10), name: "big", data: big)
        var copy = art; copy.data = Data(repeating: 7, count: 20_000_000)
        let t0 = Date()
        for _ in 0..<10 { var h = Hasher(); h.combine(Element.art(art)); _ = h.finalize() }
        let ms = Date().timeIntervalSince(t0) * 1000
        var changed = copy; changed.data[10_000_001] = 1
        check("hashing a 20 MB embedded picture ten times takes under 10 ms; equal art hashes equal, changed art isn't equal",
              ms < 10 && art.hashValue == copy.hashValue && art == copy && changed != art, String(format: "%.2f ms", ms))

        // 8. Edit… on another version of a component whose editor is open shows that version there
        var c = Component(name: "Versions")
        c.versions = (1...3).map { ComponentVersion(number: $0, width: 200 + CGFloat($0) * 10, height: 50) }
        let url = URL(fileURLWithPath: "/nonexistent/Versions.typesetcomponent")
        defer { ComponentEditorWindows.shared.closeAll() }
        let v3 = ComponentEditor(component: c, version: 3, fileURL: url)
        v3.undoManager = nil
        let first = ComponentEditorWindows.shared.open(v3, store: nil)
        let count = ComponentEditorWindows.shared.editors.count
        let second = ComponentEditorWindows.shared.open(ComponentEditor(component: c, version: 1, fileURL: url), store: nil)
        check("Edit… on v1 with v3's editor open shows v1 in that editor", second === first && first.base == 1
              && first.draft.width == 210 && ComponentEditorWindows.shared.editors.count == count, "base \(first.base ?? -1)")
        let third = ComponentEditorWindows.shared.open(ComponentEditor(component: c, fileURL: url), store: nil)
        check("…and Edit… with no version asked for leaves it on the version it shows", third === first && first.base == 1)
    }
}
