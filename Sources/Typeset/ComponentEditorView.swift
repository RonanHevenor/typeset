import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The component editor's window (phase 6): the tools along the top, the canvas, and the inspector (the selected
// element, the component itself, and its version history). The canvas is one AppKit view that draws everything
// and takes every press, move and release, feeding the editor's pointer state machine in page points; what's
// under the pointer always comes from `CanvasHitTest`, so click, hover, cursor, drag start and right-click agree.

struct ComponentEditorView: View {
    @Environment(ComponentEditor.self) private var editor

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                EditorToolbar()
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    EditorCanvas(editor: editor, key: editor.drawKey)
                        .frame(width: HouseStyle.page.width * editor.zoom + 2 * ComponentEditor.pad,
                               height: HouseStyle.page.height * editor.zoom + 2 * ComponentEditor.pad)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
            Divider()
            EditorInspector { EmptyView() }
                .frame(width: 300)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: editor.title, initial: true) {
            guard let w = ComponentEditorWindows.shared.window(for: editor) else { return }
            w.title = editor.name
            w.subtitle = editor.base.map { editor.isEdited ? "Component · edited from v\($0)" : "Component · v\($0)" } ?? "Component · not saved"
            w.isDocumentEdited = editor.isEdited
            w.representedURL = editor.fileURL
        }
    }
}

extension ComponentEditor {
    /// Everything the canvas draws from, so the view draws again when any of it changes.
    var drawKey: Int {
        var h = Hasher()
        h.combine(draft); h.combine(name); h.combine(origin.x); h.combine(origin.y); h.combine(selection)
        h.combine(hovered); h.combine(hoverEdge.map { "\($0)" }); h.combine(zoom); h.combine(pointer.phase)
        h.combine(pointer.zone.map { "\($0)" }); h.combine(pointer.marquee?.width); h.combine(pointer.marquee?.height)
        h.combine(guides); h.combine(pageColumns); h.combine(tool)
        return h.finalize()
    }
}

// MARK: - the tools

struct EditorToolbar: View {
    @Environment(ComponentEditor.self) private var editor
    /// In the in-place editor (phase 7) the pages' zoom applies and saving is on its own bar.
    var inPlace = false
    static func weight(_ w: CGFloat) -> String { String(format: "%g pt", Double(w)) }

    var body: some View {
        @Bindable var e = editor
        HStack(spacing: 10) {
            Picker("Tool", selection: $e.tool) {
                ForEach(EditorTool.allCases) { t in Image(systemName: t.symbol).help(t.title).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if editor.tool == .frame {
                Picker("Type", selection: $e.frameType) { FrameTypeOptions() }
                    .fixedSize()
                    .help("What the new frame is for")
                Picker("Link", selection: $e.frameLink) { LinkOptions() }
                    .fixedSize()
                    .disabled(editor.frameType.isIssueField || editor.frameType == .ad)
                    .help("Frames with the same letter take one story between them")
            }
            ColorPicker("Fill", selection: Binding(get: { Color(nsColor: editor.fillColor.nsColor) },
                                                   set: { editor.applyFill(Paint(NSColor($0))) }), supportsOpacity: false)
                .fixedSize()
                .help("The fill colour: new shapes take it, and it's put on the selection")
            Menu {
                ForEach(ComponentEditor.lineWeights, id: \.self) { w in
                    Button { editor.applyLineWeight(w) } label: {
                        if w == editor.lineWeight { Label(Self.weight(w), systemImage: "checkmark") } else { Text(Self.weight(w)) }
                    }
                }
            } label: {
                Label(Self.weight(editor.lineWeight), systemImage: "line.3.horizontal.decrease")
            }
            .fixedSize()
            .help("The line weight: new lines take it, and it's put on the selected line or shape's stroke")
            Button { placeArtPanel(editor) } label: { Label("Place Art…", systemImage: "photo") }
                .help("An image or PDF, embedded in the component")
            Spacer()
            if !inPlace {
            Button { editor.zoom = (editor.zoom / 1.25).clamped(0.25, 3) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int((editor.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
            Button { editor.zoom = (editor.zoom * 1.25).clamped(0.25, 3) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Save Version") { editor.saveCommand() }
                .disabled(!editor.isEdited)
                .help("Makes what's here the next version of the component")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct FrameTypeOptions: View {
    var body: some View {
        Section("Story") {
            ForEach(FrameType.allCases.filter(\.isStoryField)) { Text($0.title).tag($0) }
        }
        Section("Ad") { Text(FrameType.ad.title).tag(FrameType.ad) }
        Section("Issue") {
            ForEach(FrameType.allCases.filter(\.isIssueField)) { Text($0.title).tag($0) }
        }
    }
}

private struct LinkOptions: View {
    var body: some View {
        Text("Not linked").tag(String?.none)
        ForEach(["A", "B", "C", "D", "E", "F"], id: \.self) { Text("Story \($0)").tag(String?.some($0)) }
    }
}

@MainActor
func placeArtPanel(_ editor: ComponentEditor) {
    let panel = NSOpenPanel()
    panel.title = "Place Art"
    panel.allowedContentTypes = [.image, .pdf]
    guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
    if editor.placeArt(data: data, name: url.lastPathComponent) == nil {
        ComponentFiles.alert("“\(url.lastPathComponent)” can't be placed", "Typeset can place an image or a PDF.")
    }
}

// MARK: - the inspector

struct EditorInspector<Header: View>: View {
    @Environment(ComponentEditor.self) private var editor
    /// In place (phase 7): the name stays the component's; `header` says what's open and how to leave.
    var inPlace = false
    @ViewBuilder var header: () -> Header

    var body: some View {
        Form {
            header()
            if let el = editor.selectedElement {
                Section(el.kindTitle) { ElementControls(element: el) }
            }
            Section("Component") { ComponentControls(inPlace: inPlace) }
            Section("Versions") { VersionHistory() }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}

/// A number field that commits on Return or when it loses focus.
private struct NumberField: View {
    let title: String
    let value: CGFloat?
    var placeholder = ""
    let set: (CGFloat?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(placeholder))
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { if !focused { text = format(value) } }
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
    }
    private func format(_ v: CGFloat?) -> String { v.map { String(format: "%g", Double(($0 * 10).rounded() / 10)) } ?? "" }
    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { if value != nil { set(nil) }; return }
        if let d = Double(t) { if CGFloat(d) != value { set(CGFloat(d)) } } else { text = format(value) }
    }
}

private struct ElementControls: View {
    @Environment(ComponentEditor.self) private var editor
    let element: Element

    var body: some View {
        let id = element.id
        let b = element.box
        HStack {
            NumberField(title: "X", value: b.x) { v in editor.update(id, "Move") { $0.box.x = v ?? b.x } }
            NumberField(title: "Y", value: b.y) { v in editor.update(id, "Move") { $0.box.y = v ?? b.y } }
        }
        HStack {
            NumberField(title: "W", value: b.w) { v in editor.update(id, "Resize") { $0.box.w = max(0, v ?? b.w) } }
            NumberField(title: "H", value: b.h) { v in editor.update(id, "Resize") { $0.box.h = max(0, v ?? b.h) } }
        }
        switch element {
        case .frame(let f): FrameControls(frame: f)
        case .text(let t): TextControls(text: t)
        case .rect(let s), .ellipse(let s): ShapeControls(id: id, shape: s)
        case .line(let l): LineControls(line: l)
        case .art(let a):
            LabeledContent("File", value: a.name)
        }
        HStack {
            Button("Bring to Front") { editor.bringToFront(id) }
            Button("Send to Back") { editor.sendToBack(id) }
        }
        HStack {
            Button("Duplicate") { editor.duplicate(id) }
            Button("Delete", role: .destructive) { editor.delete(id) }
        }
    }
}

/// A frame allows a type, a link letter, a size and an alignment (decision 7); a date frame its format.
private struct FrameControls: View {
    @Environment(ComponentEditor.self) private var editor
    let frame: Frame

    private func set(_ name: String, _ change: @escaping (inout Frame) -> Void) {
        editor.update(frame.id, name) { e in if case .frame(var f) = e { change(&f); e = .frame(f) } }
    }

    var body: some View {
        Picker("Type", selection: Binding(get: { frame.type }, set: { t in set("Frame Type") { f in
            f.type = t
            if t.isIssueField || t == .ad { f.link = nil }
            if t == .date, f.dateFormat == nil { f.dateFormat = Frame.defaultDateFormat }
        } })) { FrameTypeOptions() }
        Picker("Link", selection: Binding(get: { frame.link }, set: { l in set("Link") { $0.link = l } })) { LinkOptions() }
            .disabled(frame.type.isIssueField || frame.type == .ad)
        NumberField(title: "Size", value: frame.size, placeholder: "House style") { v in set("Type Size") { $0.size = v.map { max(4, $0) } } }
        Picker("Alignment", selection: Binding(get: { frame.alignment }, set: { a in set("Alignment") { $0.alignment = a } })) {
            Text("House style").tag(TextAlign?.none)
            Text("Left").tag(TextAlign?.some(.left))
            Text("Centre").tag(TextAlign?.some(.center))
            Text("Right").tag(TextAlign?.some(.right))
        }
        if frame.type == .date {
            TextField("Date format", text: Binding(get: { frame.dateFormat ?? Frame.defaultDateFormat },
                                                   set: { s in set("Date Format") { $0.dateFormat = s.isEmpty ? nil : s } }))
        }
        Text(frame.type.isIssueField ? "Fills itself on every page." : "Empty until a story, photo or ad is dropped on it on a page.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct TextControls: View {
    @Environment(ComponentEditor.self) private var editor
    let text: TextElement
    static let faces = ["Raleway-Bold", "Raleway-SemiBold", "Raleway-Regular", "MinionPro-Regular", "MinionPro-It", "MyriadPro-Regular", "MyriadPro-It"]

    private func set(_ name: String, _ change: @escaping (inout TextElement) -> Void) {
        editor.update(text.id, name) { e in if case .text(var t) = e { change(&t); e = .text(t) } }
    }

    var body: some View {
        TextField("Text", text: Binding(get: { text.text }, set: { s in set("Typing") { $0.text = s } }), axis: .vertical)
            .lineLimit(1...4)
        Picker("Face", selection: Binding(get: { text.face }, set: { f in set("Face") { $0.face = f } })) {
            ForEach(Self.faces + (Self.faces.contains(text.face) ? [] : [text.face]), id: \.self) { Text($0).tag($0) }
        }
        NumberField(title: "Size", value: text.size) { v in set("Type Size") { $0.size = max(4, v ?? 12) } }
        Picker("Alignment", selection: Binding(get: { text.alignment }, set: { a in set("Alignment") { $0.alignment = a } })) {
            Text("Left").tag(TextAlign.left); Text("Centre").tag(TextAlign.center); Text("Right").tag(TextAlign.right)
        }
        ColorPicker("Colour", selection: Binding(get: { Color(nsColor: text.color.nsColor) }, set: { c in set("Colour") { $0.color = Paint(NSColor(c)) } }), supportsOpacity: false)
    }
}

private struct ShapeControls: View {
    @Environment(ComponentEditor.self) private var editor
    let id: UUID
    let shape: ShapeElement

    private func set(_ name: String, _ change: @escaping (inout ShapeElement) -> Void) {
        editor.update(id, name) { e in
            switch e {
            case .rect(var s): change(&s); e = .rect(s)
            case .ellipse(var s): change(&s); e = .ellipse(s)
            default: break
            }
        }
    }

    var body: some View {
        Toggle("Fill", isOn: Binding(get: { shape.fill != nil }, set: { on in set("Fill") { $0.fill = on ? editor.fillColor : nil } }))
        if let f = shape.fill {
            ColorPicker("Fill colour", selection: Binding(get: { Color(nsColor: f.nsColor) }, set: { c in set("Fill Colour") { $0.fill = Paint(NSColor(c)) } }), supportsOpacity: false)
        }
        Toggle("Stroke", isOn: Binding(get: { shape.stroke != nil }, set: { on in set("Stroke") { $0.stroke = on ? .ink : nil } }))
        if let k = shape.stroke {
            ColorPicker("Stroke colour", selection: Binding(get: { Color(nsColor: k.nsColor) }, set: { c in set("Stroke Colour") { $0.stroke = Paint(NSColor(c)) } }), supportsOpacity: false)
            NumberField(title: "Stroke width", value: shape.strokeWidth) { v in set("Stroke Width") { $0.strokeWidth = max(0, v ?? 0.5) } }
        }
    }
}

private struct LineControls: View {
    @Environment(ComponentEditor.self) private var editor
    let line: LineElement

    private func set(_ name: String, _ change: @escaping (inout LineElement) -> Void) {
        editor.update(line.id, name) { e in if case .line(var l) = e { change(&l); e = .line(l) } }
    }

    var body: some View {
        ColorPicker("Colour", selection: Binding(get: { Color(nsColor: line.color.nsColor) }, set: { c in set("Colour") { $0.color = Paint(NSColor(c)) } }), supportsOpacity: false)
        HStack {
            NumberField(title: "Weight (pt)", value: line.width) { v in set("Line Weight") { $0.width = max(0.1, v ?? 0.5) } }
            Stepper("Weight", value: Binding(get: { Double(line.width) }, set: { v in set("Line Weight") { $0.width = max(0.1, CGFloat(v)) } }),
                    in: 0.1...24, step: 0.25)
                .labelsHidden()
        }
    }
}

/// The component itself: its name, size, columns and gutter (decision 8: both default to the page's).
private struct ComponentControls: View {
    @Environment(ComponentEditor.self) private var editor
    var inPlace = false

    var body: some View {
        if inPlace {
            LabeledContent("Name", value: editor.name)
        } else {
            TextField("Name", text: Binding(get: { editor.name }, set: { editor.setName($0) }))
        }
        HStack {
            NumberField(title: "Width", value: editor.draft.width) { v in if let v { editor.setSize(width: v) } }
            NumberField(title: "Height", value: editor.draft.height) { v in if let v { editor.setSize(height: v) } }
        }
        Text(String(format: "%.2f × %.2f in. Pull its edges on the canvas: they snap to the page's margins, its columns and the full page.", editor.draft.width / 72, editor.draft.height / 72))
            .font(.caption).foregroundStyle(.secondary)
        Picker("Columns", selection: Binding(get: { editor.draft.columns }, set: { editor.setColumns($0) })) {
            Text("The page's (\(editor.pageColumns))").tag(Int?.none)
            ForEach(1...8, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        NumberField(title: "Gutter", value: editor.draft.gutter, placeholder: "The page's (\(Int(HouseStyle.gutter)) pt)") { editor.setGutter($0) }
    }
}

private struct VersionHistory: View {
    @Environment(ComponentEditor.self) private var editor

    var body: some View {
        if editor.versions.isEmpty {
            Text("Not saved yet. Save Version makes this version 1.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(editor.versions.reversed(), id: \.number) { v in
            HStack {
                Image(nsImage: ComponentThumbnail.image(v, height: 24))
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 56, height: 24)
                    .background(Color.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("v\(v.number)" + (v.number == editor.base ? (editor.isEdited ? " (base, edited)" : " (open)") : ""))
                        .font(.callout.weight(v.number == editor.base ? .semibold : .regular))
                    Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if v.number != editor.base || editor.isEdited {
                    Button("Open") { openVersion(v.number) }
                        .help("Show this version; your next save builds on it")
                }
            }
        }
        if let url = editor.fileURL {
            Text((url.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }

    private func openVersion(_ n: Int) {
        if editor.isEdited, editor.base != nil {
            let a = NSAlert()
            a.messageText = "Open version \(n)?"
            a.informativeText = "What you've changed since the last save stays in Undo, but isn't a version until you save it."
            a.addButton(withTitle: "Open v\(n)")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        editor.openVersion(n)
    }
}

// MARK: - the canvas

struct EditorCanvas: NSViewRepresentable {
    let editor: ComponentEditor
    let key: Int

    func makeNSView(context: Context) -> EditorCanvasView {
        let v = EditorCanvasView()
        v.editor = editor
        return v
    }

    func updateNSView(_ v: EditorCanvasView, context: Context) {
        v.editor = editor
        v.needsDisplay = true
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

final class EditorCanvasView: NSView {
    weak var editor: ComponentEditor?
    private var tracking: NSTrackingArea?
    /// In place on a page (phase 7): no margin round the page, and only the component is drawn (the page under it
    /// is the Pages canvas's, faded); Escape with nothing left to let go of calls `onLeave`.
    var inPlace = false
    var onLeave: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var zoom: CGFloat { editor?.zoom ?? 1 }
    private var pad: CGFloat { inPlace ? 0 : ComponentEditor.pad }

    /// A point in this view, in page points.
    func pagePoint(_ local: CGPoint) -> CGPoint { CGPoint(x: (local.x - pad) / zoom, y: (local.y - pad) / zoom) }
    /// A rect in page points, in this view.
    func viewRect(_ r: CGRect) -> CGRect { CGRect(x: pad + r.minX * zoom, y: pad + r.minY * zoom, width: r.width * zoom, height: r.height * zoom) }
    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: pad + p.x * zoom, y: pad + p.y * zoom) }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard let editor else { return }
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        // a plain move with a gesture still open: its mouse-up was lost while the window stayed key (rule 6)
        if editor.pointer.isActive, NSEvent.pressedMouseButtons & 1 == 0 { editor.pointerHoverButtonUp(at: p) } else { editor.pointerHover(at: p) }
        editor.cursor(at: p).set()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        guard let editor, !editor.pointer.isActive else { return }
        editor.pointerHover(at: nil)
        NSCursor.arrow.set()
    }

    // MARK: the press

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        window?.makeFirstResponder(self)
        editor.pointerDown(at: pagePoint(convert(event.locationInWindow, from: nil)), modifiers: .init(event.modifierFlags), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor, editor.pointer.isActive else { return }
        autoscroll(with: event)
        editor.pointerMoved(to: pagePoint(convert(event.locationInWindow, from: nil)), modifiers: .init(event.modifierFlags))
        switch editor.pointer.phase {
        case .dragging: NSCursor.closedHand.set()
        case .resizing: editor.pointer.zone?.cursor.set()
        case .creating, .marquee: NSCursor.crosshair.set()
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor, editor.pointer.isActive else { return }
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        editor.pointerUp(at: p, modifiers: .init(event.modifierFlags))
        editor.pointerHover(at: p)
        editor.cursor(at: p).set()
    }

    /// Right-click: the menu is for what the hit test puts under the pointer, the same answer a click gets.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let editor else { return nil }
        let p = pagePoint(convert(event.locationInWindow, from: nil))
        editor.pointerHover(at: p)
        let menu = NSMenu()
        switch ComponentEditor.selection(of: editor.hit(at: p)) {
        case .element(let id):
            menu.addItem(ClosureMenuItem("Bring to Front") { editor.bringToFront(id) })
            menu.addItem(ClosureMenuItem("Send to Back") { editor.sendToBack(id) })
            menu.addItem(ClosureMenuItem("Duplicate") { editor.duplicate(id) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete") { editor.delete(id) })
        case .component:
            menu.addItem(ClosureMenuItem("Place Art…") { placeArtPanel(editor) })
            if inPlace {
                if let onLeave { menu.addItem(ClosureMenuItem("Done Editing") { onLeave() }) }
            } else {
                menu.addItem(ClosureMenuItem("Save Version", enabled: editor.isEdited) { editor.saveCommand() })
            }
        case nil:
            return nil
        }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: editor.deleteSelection()                       // delete, forward delete
        case 123: editor.nudge(dx: -step, dy: 0)
        case 124: editor.nudge(dx: step, dy: 0)
        case 125: editor.nudge(dx: 0, dy: step)
        case 126: editor.nudge(dx: 0, dy: -step)
        case 53:                                                        // escape: a gesture, then a tool, then the selection
            if editor.pointer.isActive { editor.pointerCancelled() } else if editor.tool != .select { editor.tool = .select }
            else if editor.selection != nil || !inPlace { editor.selection = nil } else { onLeave?() }
        default: super.keyDown(with: event)
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = zoom
        let pageRect = viewRect(CGRect(origin: .zero, size: HouseStyle.page))
        let comp = viewRect(editor.rect)
        if inPlace {
            // in place: the page underneath is the Pages canvas's own, faded; the component is drawn over it in full
            // colour, on white, as it's being edited (its frames as frames)
            NSColor.white.setFill(); comp.fill()
            ctx.saveGState()
            ctx.translateBy(x: pad, y: pad)
            ctx.scaleBy(x: z, y: z)
            editor.rect.clip()
            editor.composedPage()?.draw(guides: false, markers: true)
            ctx.restoreGState()
        } else {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 6; shadow.shadowColor = .black.withAlphaComponent(0.25); shadow.set()
        NSColor.white.setFill(); pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        // the page, set as the pages set it: the component, its empty frames' placeholders, issue fields filled
        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)
        ctx.scaleBy(x: z, y: z)
        CGRect(origin: .zero, size: HouseStyle.page).clip()
        editor.composedPage()?.draw(guides: false, markers: true)
        ctx.restoreGState()

        // the rest of the page faded, with its margins and columns
        let wash = NSBezierPath(rect: pageRect)
        wash.append(NSBezierPath(rect: comp))
        wash.windingRule = .evenOdd
        NSColor(white: 0.93, alpha: 0.7).setFill(); wash.fill()
        // the page's columns and margins where the pages draw them (an inside page's top), kept off the
        // component, which shows exactly as it's placed
        NSGraphicsContext.saveGraphicsState()
        wash.addClip()
        let g = Grid(columns: editor.pageColumns)
        let top = HouseStyle.insideTop
        NSColor.systemBlue.withAlphaComponent(0.05).setFill()
        for c in 0..<g.columns {
            viewRect(CGRect(x: g.x(c), y: top, width: g.colWidth, height: HouseStyle.bottom - top)).fill(using: .sourceOver)
        }
        let margins = NSBezierPath(rect: viewRect(CGRect(x: HouseStyle.margin, y: top, width: HouseStyle.liveWidth, height: HouseStyle.bottom - top)))
        margins.lineWidth = 1
        margins.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemPink.withAlphaComponent(0.5).setStroke(); margins.stroke()
        NSGraphicsContext.restoreGraphicsState()
        }

        // the component's own columns, and its edge
        NSColor.systemTeal.withAlphaComponent(0.08).setFill()
        for r in editor.columnRects { viewRect(r).fill(using: .sourceOver) }
        NSColor.systemTeal.withAlphaComponent(0.35).setStroke()
        for r in editor.columnRects {
            let p = NSBezierPath(rect: viewRect(r).insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 0.5; p.stroke()
        }
        let edge = NSBezierPath(rect: comp.insetBy(dx: -0.5, dy: -0.5))
        edge.lineWidth = 1
        NSColor.secondaryLabelColor.setStroke(); edge.stroke()

        // each frame's box and what it's for
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        for e in editor.draft.elements {
            guard case .frame(let f) = e else { continue }
            let r = viewRect(editor.pageRect(e))
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1; p.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.systemPurple.withAlphaComponent(0.7).setStroke(); p.stroke()
            let s = NSAttributedString(string: f.type.title + (f.link.map { " · \($0)" } ?? ""), attributes: label)
            let tag = CGRect(x: r.minX, y: r.minY, width: s.size().width + 6, height: 12)
            NSColor.systemPurple.withAlphaComponent(0.8).setFill(); tag.fill()
            s.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY))
        }

        let accent = NSColor.controlAccentColor
        // what the pointer is over, as the hit test sees it
        if !editor.pointer.isActive, let h = editor.hovered, h != editor.selection, editor.tool == .select, let r = editor.pageRect(of: h) {
            outline(h, r, editor, color: accent.withAlphaComponent(0.6), width: 1)
        }
        // the selection: outline, handles, the edge under the pointer
        if let sel = editor.selection, let r = editor.pageRect(of: sel) {
            outline(sel, r, editor, color: accent, width: editor.pointer.phase == .dragging ? 2.5 : 1.5)
            if editor.pointer.phase != .dragging {
                let zone = editor.pointer.phase == .resizing || editor.pointer.phase == .pressed ? editor.pointer.hit?.edge : editor.hoverEdge
                if let zone { edgeHighlight(zone, viewRect(r), accent) }
                for c in handles(sel, editor) {
                    let pt = CGPoint(x: viewRect(r).minX + c.unit.x * r.width * z, y: viewRect(r).minY + c.unit.y * r.height * z)
                    let dot = NSBezierPath(ovalIn: CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9))
                    NSColor.white.setFill(); dot.fill()
                    accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
        }
        // guides while something snaps
        accent.withAlphaComponent(0.8).setStroke()
        for gd in editor.guides {
            let p = NSBezierPath()
            switch gd.axis {
            case .x: p.move(to: viewPoint(CGPoint(x: gd.at, y: 0))); p.line(to: viewPoint(CGPoint(x: gd.at, y: HouseStyle.page.height)))
            case .y: p.move(to: viewPoint(CGPoint(x: 0, y: gd.at))); p.line(to: viewPoint(CGPoint(x: HouseStyle.page.width, y: gd.at)))
            }
            p.lineWidth = 1; p.stroke()
        }
        if let m = editor.pointer.marquee {
            let p = NSBezierPath(rect: viewRect(m)); p.setLineDash([4, 3], count: 2, phase: 0); p.lineWidth = 1
            accent.setStroke(); p.stroke()
        }
        // the size, under the component's corner
        let size = NSAttributedString(string: String(format: "%.0f × %.0f pt", editor.draft.width, editor.draft.height),
                                      attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        size.draw(at: CGPoint(x: comp.maxX - size.size().width, y: comp.maxY + 4))
    }

    private func outline(_ sel: EditorSelection, _ r: CGRect, _ editor: ComponentEditor, color: NSColor, width: CGFloat) {
        color.setStroke()
        if case .element(let id) = sel, case .line(let l)? = editor.element(id) {
            let p = NSBezierPath()
            p.move(to: viewPoint(CGPoint(x: l.x1 + editor.origin.x, y: l.y1 + editor.origin.y)))
            p.line(to: viewPoint(CGPoint(x: l.x2 + editor.origin.x, y: l.y2 + editor.origin.y)))
            p.lineWidth = max(width + 2, l.width * zoom + 2)
            color.withAlphaComponent(0.4).setStroke(); p.stroke()
            return
        }
        let p = NSBezierPath(rect: viewRect(r).insetBy(dx: -0.5, dy: -0.5))
        p.lineWidth = width; p.stroke()
    }

    /// The handles drawn on a selection: a line's two ends, everything else's eight.
    private func handles(_ sel: EditorSelection, _ editor: ComponentEditor) -> [ResizeZone] {
        guard case .element(let id) = sel, case .line(let l)? = editor.element(id) else { return ResizeZone.allCases }
        if abs(l.y1 - l.y2) < 0.01 { return [.w, .e] }
        if abs(l.x1 - l.x2) < 0.01 { return [.n, .s] }
        return (l.x1 < l.x2) == (l.y1 < l.y2) ? [.nw, .se] : [.ne, .sw]
    }

    private func edgeHighlight(_ zone: ResizeZone, _ r: CGRect, _ color: NSColor) {
        let p = NSBezierPath()
        let e = zone.edges
        if e.contains(.top) { p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.minY)) }
        if e.contains(.bottom) { p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.line(to: CGPoint(x: r.maxX, y: r.maxY)) }
        if e.contains(.left) { p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.minX, y: r.maxY)) }
        if e.contains(.right) { p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.maxY)) }
        p.lineWidth = 3; p.lineCapStyle = .square
        color.setStroke(); p.stroke()
    }
}
