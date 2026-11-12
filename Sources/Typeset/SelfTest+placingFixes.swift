import AppKit

/// Phase 5 review fixes: a selected component's or picture's outer edge band over what it sits on; an ad refused
/// by a linked image frame; a near miss while carrying a frame's content; On Hold counted one way for the sidebar
/// and the Switch Version warning; fills keyed by frame and by letter reconciled across versions; fills of a
/// deleted story or ad let go. Called at the end of placingChecks, on its staged pages; its defer puts it all back.
extension SelfTest {
    @MainActor
    static func placingFixes(_ store: IssueStore, _ check: (String, Bool, String) -> Void, card id: PlacedComponent.ID, page pg: Int, page2 pg2: Int,
                             undo: UndoManager, frames: (head: Frame, picA: Frame, left: Frame, right: Frame, body: Frame), a: Article, b: Article,
                             drag: (CGPoint, CGSize, Int, IssueStore.PointerModifiers) -> Void) {
        // every command that registers undo is its own step (see placingChecks): the manager doesn't group by event
        @discardableResult func step<T>(_ f: () -> T) -> T { undoStep(undo, f) }
        func fresh() { step { store.pointerCancelled() }; undo.removeAllActions(); store.canvasSelection = nil }
        func target(_ placed: PlacedComponent.ID, _ f: Frame) -> IssueStore.FrameTarget? { store.frameTargets(placed).first { $0.frame.id == f.id } }
        guard let f0 = store.placedComponent(id)?.placed.frame.rect else { check("fixes: the test card on its page", false, ""); return }

        // rule 4: the selected component's outer band, over a story it sits on
        fresh()
        if let sb = step({ store.addBlock(a.id, on: pg) }) {
            step { store.edit("Stage") { store.setBlockFrame(sb, page: pg, frame: f0.insetBy(dx: -60, dy: -60)) } }
            store.canvasSelection = .component(id)
            let out = store.hit(at: CGPoint(x: f0.maxX + 3, y: f0.midY), on: pg)
            check("rule 4: a selected component's edge is live 3 pt outside it, over the story it sits on",
                  out.edge == .e && out.what == .component(id), "\(out.what) \(String(describing: out.edge))")
            store.canvasSelection = nil
            check("  unselected, that point is the story's", store.hit(at: CGPoint(x: f0.maxX + 3, y: f0.midY), on: pg).what == .block(sb), "")
            step { store.removeBlock(sb) }
        } else { check("rule 4: a story block to try", false, "") }
        do {
            let comp = UUID(), pic = UUID(), cf = CGRect(x: 100, y: 100, width: 300, height: 200)
            let picture = CGRect(x: 200, y: 150, width: 100, height: 80)
            let items = [CanvasHitTest.Item(selection: .component(comp), shape: cf, kind: nil),
                         CanvasHitTest.Item(selection: .inset(pic), shape: picture, kind: .photo, hosts: [comp])]
            let h = CanvasHitTest.hit(CGPoint(x: picture.maxX + 3, y: picture.midY), items: items, selected: .inset(pic), zoom: 1)
            check("  a selected picture's edge is live 3 pt outside it, over the component it sits on", h.edge == .e && h.what == .inset(pic), "\(h.what)")
        }

        // an ad on a linked image frame would empty its group: refused; an unlinked image frame takes it
        check("filling: a linked image frame doesn't take an ad; an unlinked one does",
              !store.accepts(frames.picA, .extra(UUID())) && store.accepts(frames.left, .extra(UUID())), "")

        // carrying a frame's picture: let go over a frame that doesn't take it, or on its own component, nothing changes
        fresh()
        store.canvasSelection = .component(id)
        if let tr = target(id, frames.right), let th = target(id, frames.head), let tb = target(id, frames.body), store.fill(of: tr) != nil {
            let before = store.placedComponent(id)?.placed.fills
            let from = CGPoint(x: tr.rect.midX, y: tr.rect.midY)
            drag(from, CGSize(width: th.rect.midX - from.x, height: th.rect.midY - from.y), pg, [.option])
            check("pulling: a picture let go over a headline frame stays where it was, no undo step",
                  store.placedComponent(id)?.placed.fills == before && !undo.canUndo, "")
            drag(from, CGSize(width: tb.rect.minX + 4 - from.x, height: tb.rect.maxY - 2 - from.y), pg, [.option])
            check("  and over the body frame too", store.placedComponent(id)?.placed.fills == before && !undo.canUndo, "")
        } else { check("pulling: a filled picture frame to pull from", false, "") }

        // a second card: F unlinked in v1 and linked B in v2; C a headline and body in v1, the headline only in v2
        let F = Frame(type: .image, box: Box(x: 0, y: 0, w: 140, h: 80))
        var F2 = F; F2.link = "B"
        let hB = Frame(type: .headline, box: Box(x: 150, y: 0, w: 150, h: 30), link: "B", size: 20)
        let hC = Frame(type: .headline, box: Box(x: 0, y: 90, w: 300, h: 30), link: "C", size: 20)
        let bC = Frame(type: .body, box: Box(x: 0, y: 124, w: 300, h: 76), link: "C")
        let lv1 = ComponentVersion(number: 1, width: 300, height: 200, columns: 2, gutter: 12, elements: [.frame(F), .frame(hC), .frame(bC)])
        let lv2 = ComponentVersion(number: 2, width: 300, height: 200, columns: 2, gutter: 12, elements: [.frame(F2), .frame(hB), .frame(hC)])
        let linkCard = Component(name: "Link Card", versions: [lv1, lv2])
        store.issue.embed(linkCard, version: 1)
        store.issue.embed(linkCard, version: 2)
        fresh()
        guard let lid = step({ store.placeComponent(linkCard.id, version: 1, on: pg2, at: CGPoint(x: 120, y: 400)) }),
              let tF = target(lid, F), let tC = target(lid, bC), let photo = b.photos.first else { check("versions: a linked card to switch", false, ""); return }
        step { store.parkStory(a.id) }
        step { store.fillFrame(.story(a.id), tC) }
        step { store.edit("Stage") { store.setFill(Fill(frame: F.id, article: b.id, photo: photo.id), of: tF) } }
        check("On Hold: the sidebar and the warning count running stories the same way",
              Set(store.storyStatus().keys) == store.runningStories() && store.runningStories().contains(a.id),
              "sidebar \(store.storyStatus().count), warning \(store.runningStories().count)")
        let (onHold, emptied) = store.switchVersionLosses(lid, to: 2)
        check("  a story carried by its letter into a version with no body frame for it is listed as going back on hold",
              onHold.contains(a.plainHeadline) && !emptied.contains(a.plainHeadline), "on hold \(onHold), leaving \(emptied)")
        step { store.switchVersion(lid, to: 2) }
        let s2 = store.placedComponent(lid)?.placed
        check("versions: a fill on a frame that's linked in the new version is carried by its letter",
              s2?.fill(for: hB)?.article == b.id && s2?.fill(for: F2)?.photo == photo.id && s2?.fills.count == 2, "\(s2?.fills.count ?? -1) fills")
        check("  and the story that went back on hold is in On Hold", store.storyStatus()[a.id] == nil, "")
        if let tF2 = target(lid, F2), let other = a.photos.first {
            step { store.fillFrame(.photo(a.id, other.id), tF2) }
            let s3 = store.placedComponent(lid)?.placed
            check("  a new drop on that frame replaces it", s3?.fills.filter { $0.link == "B" || $0.frame == F.id }.count == 1 && s3?.fill(for: F2)?.article == a.id, "")
            step { store.clearFrame(tF2) }
            check("  and clearing it empties it: the old content doesn't come back", store.placedComponent(lid)?.placed.fill(for: F2) == nil, "")
            undo.undo(); undo.undo()
        }
        step { store.switchVersion(lid, to: 1) }
        let s4 = store.placedComponent(lid)?.placed
        check("  switched back where the letter is gone, the fill stays on the frame that's still there",
              s4?.fill(for: F)?.article == b.id,
              s4.map { p in "v\(p.version), fills " + p.fills.map { "\($0.link ?? "-")/\($0.frame == F.id ? "F" : ($0.frame == nil ? "-" : "?"))/\($0.article == b.id ? "b" : ($0.article == a.id ? "a" : "?"))" }.joined(separator: " ") } ?? "the card is gone")

        // deleting a story or an ad lets go of its fills
        fresh()
        if let e = store.issue.extras.first, let tl = target(id, frames.left) {
            step { store.fillFrame(.extra(e.id), tl) }
            step { store.removeExtra(e.id) }
            check("deleting: an ad that's deleted leaves no fill behind", !store.issue.layout!.pages.flatMap(\.components).flatMap(\.fills).contains { $0.extra == e.id }, "")
            undo.undo()
            check("  undo puts it back in its frame", store.fill(of: tl)?.extra == e.id,
                  "frame holds \(store.fill(of: tl).map { store.describe($0) } ?? "nothing"); ad in the issue \(store.extra(e.id) != nil)")
        } else { check("deleting: an ad's fills", true, "no ad in the issue; skipped") }
        let sel = store.selection
        store.delete(b.id)
        store.selection = sel
        check("  a story that's deleted leaves no fill behind", !store.issue.layout!.pages.flatMap(\.components).flatMap(\.fills).contains { $0.article == b.id }, "")
    }
}
