import AppKit

// The in-place editor (phase 7): double-click a placed component and it opens for editing right where it sits on
// the page, with phase 6's editor (its model `ComponentEditor`, its pointer state machine and its views), the
// component in full colour and the rest of the paper greyscale, faded and taking no clicks. Leaving keeps what was
// changed as the placement's own copy ("Header custom"); Save as New Version makes that copy the component's next
// version, and Revert to vN puts the version back.

/// A placed component open in the in-place editor.
struct InPlaceEdit {
    var placed: PlacedComponent.ID
    var page: Int
    let editor: ComponentEditor
    /// What the editor started from (the version as drawn on the page, stretched to its frame) and where.
    var start: ComponentVersion
    var startOrigin: CGPoint
    var startBase: Int?
}

extension IssueStore {
    /// The version a placed component draws, with its stretch on the page put into its boxes: what the page shows,
    /// at the placement's size, so the editor shows exactly what's there. Type keeps its size (decision 6).
    func drawnVersion(_ id: PlacedComponent.ID) -> ComponentVersion? {
        guard let r = resolvedComponent(id) else { return nil }
        var v = r.version
        let sx = r.scaleX, sy = r.scaleY
        guard abs(sx - 1) > 0.0001 || abs(sy - 1) > 0.0001 else { return v }
        v.elements = v.elements.map { e in
            var e = e
            let b = e.box
            e.box = Box(x: b.x * sx, y: b.y * sy, w: b.w * sx, h: b.h * sy)
            return e
        }
        v.width = r.frame.width; v.height = r.frame.height
        return v
    }

    /// Double-click on a placed component: open it in place. The pages' selection is let go of; the editor
    /// shares the window's undo, and its steps fold into one when it closes.
    @discardableResult
    func enterInPlace(_ id: PlacedComponent.ID) -> ComponentEditor? {
        if inPlace != nil { leaveInPlace() }
        if pointer.isActive { pointerCancelled() }
        guard let (page, p) = placedComponent(id), let v = drawnVersion(id) else { return nil }
        let history = catalogComponent(p.component)
            ?? issue.componentVersions.first { $0.id == p.component }
            ?? Component(name: issue.componentName(p.component) ?? "Component", versions: [v]).with(id: p.component)
        let e = ComponentEditor(component: history, version: p.version, fileURL: ComponentFiles.fileURL(for: p.component),
                                origin: p.frame.rect.origin, pageColumns: issue.layout?.columns ?? grid.columns)
        e.draft = v
        e.origin = p.frame.rect.origin
        e.facts = issue
        e.pageIndex = page
        e.drawsInsideOnly = true
        e.zoom = zoom
        e.undoManager = undoManager
        select([])
        hover = nil; if hoverZone != nil { hoverZone = nil }
        inPlace = InPlaceEdit(placed: id, page: page, editor: e, start: v, startOrigin: e.origin, startBase: e.base)
        focusedPage = page
        return e
    }

    /// Whether the in-place editor has changed anything since it opened.
    var inPlaceIsEdited: Bool {
        guard let ip = inPlace else { return false }
        let e = ip.editor
        return !e.draft.sameContent(as: ip.start) || e.origin != ip.startOrigin || e.base != ip.startBase
    }

    /// Done (or Escape with nothing selected): the edits become the placement's own copy, "Header custom", in one
    /// undo step; the component stays selected. Nothing changed, nothing is made custom.
    func leaveInPlace() {
        guard let ip = inPlace else { return }
        let e = ip.editor
        if e.pointer.isActive { e.pointerCancelled() }
        let edited = inPlaceIsEdited
        closeInPlace()
        guard let (page, p) = placedComponent(ip.placed),
              let k = issue.layout?.pages[page].components.firstIndex(where: { $0.id == ip.placed }) else { return }
        if edited {
            var v = e.draft
            v.number = e.base ?? p.version
            v.date = Date()
            edit("Edit \(issue.componentName(p.component) ?? "Component") in Place") {
                var q = p
                q.version = e.base ?? p.version
                q.custom = v
                q.fills = carriedFills(p, to: v)
                q.frame = Box(CGRect(origin: e.origin, size: v.size))
                issue.layout!.pages[page].components[k] = q
            }
        }
        canvasSelection = .component(ip.placed)
        focusedPage = page
    }

    /// The layout changed under an open in-place editor (a menu command, Generate, Shuffle): it follows its
    /// component to the page it's on now, or closes if the component is gone.
    /// Undo can reach past the editor's own steps into the page's (the editor shares the window's undo): when the
    /// placement itself changed under an editor with nothing edited yet (moved, resized, switched version, made
    /// custom or reverted), the editor starts again from it as it is now, so it draws where the page does and
    /// Done writes nothing stale back.
    func followInPlace() {
        guard let ip = inPlace else { return }
        guard let (page, p) = placedComponent(ip.placed) else { closeInPlace(); return }
        if page != ip.page { inPlace?.page = page; ip.editor.pageIndex = page }
        let e = ip.editor
        guard !e.pointer.isActive, !inPlaceIsEdited, let v = drawnVersion(ip.placed),
              !v.sameContent(as: ip.start) || p.frame.rect.origin != ip.startOrigin || p.version != ip.startBase else { return }
        e.savedState = (e.savedState.component, p.version, v)
        e.origin = p.frame.rect.origin
        e.facts = issue
        if let s = e.selection, case .element(let id) = s, e.element(id) == nil { e.selection = nil }
        inPlace?.start = v
        inPlace?.startOrigin = e.origin
        inPlace?.startBase = e.base
    }

    /// Closes the in-place editor without keeping anything (its own undo steps go with it).
    func closeInPlace() {
        guard let ip = inPlace else { return }
        ip.editor.undoManager?.removeAllActions(withTarget: ip.editor)
        ip.editor.undoManager = nil
        inPlace = nil
    }

    // MARK: a custom placement

    /// The version a custom placement was made from, as the issue or the catalogue has it.
    func baseVersion(of p: PlacedComponent) -> ComponentVersion? {
        catalogComponent(p.component)?.version(p.version) ?? issue.componentVersions.first { $0.id == p.component }?.version(p.version)
    }

    /// Save as New Version: a custom placement's copy becomes the component's next version, written to its file
    /// (`url`, else the file it's saved in, else one you pick, as Save Version does in the editor), and the
    /// placement shows that version. False when nothing was saved.
    @MainActor
    @discardableResult
    func saveCustomAsNewVersion(_ id: PlacedComponent.ID, to url: URL? = nil) -> Bool {
        guard let (page, p) = placedComponent(id), let custom = p.custom,
              let k = issue.layout?.pages[page].components.firstIndex(where: { $0.id == id }) else { return false }
        var c = catalogComponent(p.component)
            ?? issue.componentVersions.first { $0.id == p.component }
            ?? Component(name: issue.componentName(p.component) ?? "Component").with(id: p.component)
        guard let file = url ?? ComponentFiles.fileURL(for: p.component) ?? ComponentFiles.savePanel(c.name, title: "Save as New Version") else { return false }
        var v = custom
        v.number = (c.versions.map(\.number).max() ?? 0) + 1
        v.date = Date()
        c.versions.append(v)
        do {
            try ComponentFiles.save(c, to: file)
        } catch {
            ComponentFiles.alert("“\(c.name)” couldn't be saved", error.localizedDescription)
            return false
        }
        edit("Save as New Version") {
            issue.embed(c, version: v.number)
            var q = p
            q.version = v.number
            q.custom = nil
            issue.layout!.pages[page].components[k] = q           // same frames, same fills, same size
        }
        return true
    }

    /// Revert to vN: the placement drops its own copy and draws the version it was made from again, at the size it
    /// has now. Fills carry over by frame and link letter, as Switch Version's do. One undo step.
    func revertCustom(_ id: PlacedComponent.ID) {
        guard let (page, p) = placedComponent(id), p.custom != nil, let v = baseVersion(of: p),
              let k = issue.layout?.pages[page].components.firstIndex(where: { $0.id == id }) else { return }
        edit("Revert to v\(p.version)") {
            var q = p
            q.custom = nil
            q.fills = carriedFills(p, to: v)
            issue.layout!.pages[page].components[k] = q
        }
    }
}
