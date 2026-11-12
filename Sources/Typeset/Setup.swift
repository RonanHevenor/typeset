import SwiftUI
import AppKit
import CoreText
import Observation
import UniformTypeIdentifiers

// Setting Typeset up for a paper: the fonts the house style is set in (which don't ship with the app) and,
// optionally, the paper's name, website, staff and nameplate. All of it lives in Application Support/Typeset
// (`paper.json`, `nameplate.*`, `Fonts/`). A build can carry defaults in its bundle: `build.sh` copies anything in
// the gitignored `Resources/Private/` (paper.json, staff.json, nameplate.pdf, a seed issue) into the app.

/// The paper's own details. Every field is optional; empty means not set up yet.
struct PaperSettings: Codable, Equatable {
    var name = ""
    /// As typed ("poly.rpi.edu" or "https://poly.rpi.edu/"); `Paper.host` is the bare host.
    var website = ""
    var staff: [StaffMember] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
        staff = try c.decodeIfPresent([StaffMember].self, forKey: .staff) ?? []
    }
}

/// The settings on disk. Reads are safe from any thread (the composer's fit lanes read the website for the
/// "Read the rest at …" line).
enum Paper {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: PaperSettings?

    static var fileURL: URL { IssueStore.supportDir.appendingPathComponent("paper.json") }

    static var settings: PaperSettings {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let s = load()
        cached = s
        return s
    }

    static func save(_ s: PaperSettings) {
        lock.lock(); cached = s; lock.unlock()
        if let data = try? IssueStore.encoder().encode(s) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// The saved settings, else the bundle's defaults (paper.json, or a bare staff.json), else nothing.
    private static func load() -> PaperSettings {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: fileURL), let s = try? dec.decode(PaperSettings.self, from: d) { return s }
        if let u = Bundle.main.url(forResource: "paper", withExtension: "json"),
           let d = try? Data(contentsOf: u), let s = try? dec.decode(PaperSettings.self, from: d) { return s }
        var s = PaperSettings()
        if let u = Bundle.main.url(forResource: "staff", withExtension: "json"),
           let d = try? Data(contentsOf: u), let staff = try? dec.decode([StaffMember].self, from: d) { s.staff = staff }
        return s
    }

    /// Whether anyone has set the paper up, here or in the bundle.
    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: fileURL.path) || Bundle.main.url(forResource: "paper", withExtension: "json") != nil
    }

    /// The website without its scheme or trailing slash: "poly.rpi.edu".
    static var host: String { host(of: settings.website) }
    static func host(of website: String) -> String {
        var s = website.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// What the last block of a story that doesn't finish in print ends with.
    static var onlineLine: String { host.isEmpty ? "Read the rest online." : "Read the rest at \(host)." }

    /// Name for a new issue.
    static var publicationName: String { settings.name }

    // MARK: nameplate

    static let nameplateTypes: [UTType] = [.pdf, .png, .jpeg, .tiff, .heic]
    private static let nameplateExtensions = ["pdf", "png", "jpg", "jpeg", "tiff", "heic"]

    /// The nameplate chosen in setup, if any.
    static var userNameplate: URL? {
        nameplateExtensions.lazy.map { IssueStore.supportDir.appendingPathComponent("nameplate.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// The nameplate new issues get: the one chosen in setup, else one the build carries.
    static var nameplateURL: URL? { userNameplate ?? Bundle.main.url(forResource: "nameplate", withExtension: "pdf") }

    /// Replace the chosen nameplate with a copy of `url`, or clear it.
    static func setNameplate(_ url: URL?) throws {
        if let old = userNameplate { try FileManager.default.removeItem(at: old) }
        guard let url else { return }
        let ext = url.pathExtension.lowercased() == "jpeg" ? "jpg" : url.pathExtension.lowercased()
        try FileManager.default.copyItem(at: url, to: IssueStore.supportDir.appendingPathComponent("nameplate.\(ext)"))
    }
}

// MARK: fonts

/// One face of the house style, by the PostScript names that satisfy it.
struct FontFace: Identifiable, Hashable {
    let family: String
    let style: String
    let names: [String]
    var id: String { names[0] }
    var installed: Bool { names.contains { NSFont(name: $0, size: 12) != nil } }
}

enum FontCheck {
    /// Every face the house style sets type in.
    static let faces: [FontFace] = [
        FontFace(family: "Minion Pro", style: "Regular", names: ["MinionPro-Regular"]),
        FontFace(family: "Minion Pro", style: "Italic", names: ["MinionPro-It"]),
        FontFace(family: "Minion Pro", style: "Medium", names: ["MinionPro-Medium"]),
        FontFace(family: "Minion Pro", style: "Bold", names: ["MinionPro-Bold"]),
        FontFace(family: "Minion Pro", style: "Bold Italic", names: ["MinionPro-BoldIt"]),
        FontFace(family: "Myriad Pro", style: "Regular", names: ["MyriadPro-Regular"]),
        FontFace(family: "Myriad Pro", style: "Italic", names: ["MyriadPro-It"]),
        FontFace(family: "Utopia Std", style: "Semibold Subhead", names: ["UtopiaStd-SemiboldSubh"]),
        FontFace(family: "Utopia Std", style: "Bold Italic", names: ["UtopiaStd-BoldIt"]),
        FontFace(family: "Raleway", style: "Regular", names: ["Raleway", "Raleway-Regular"]),
        FontFace(family: "Raleway", style: "Medium", names: ["Raleway-Medium"]),
        FontFace(family: "Raleway", style: "SemiBold", names: ["Raleway-SemiBold"]),
        FontFace(family: "Raleway", style: "Bold", names: ["Raleway-Bold"]),
    ]

    struct Family: Identifiable { let name: String; let source: String; let link: URL?; var id: String { name } }
    static let families: [Family] = [
        Family(name: "Minion Pro", source: "Adobe. Included with Adobe Fonts (Creative Cloud) or licensed from Adobe.",
               link: URL(string: "https://fonts.adobe.com/fonts/minion")),
        Family(name: "Myriad Pro", source: "Adobe. Included with Adobe Fonts (Creative Cloud) or licensed from Adobe.",
               link: URL(string: "https://fonts.adobe.com/fonts/myriad")),
        Family(name: "Utopia Std", source: "Adobe. Included with Adobe Fonts (Creative Cloud) or licensed from Adobe.",
               link: URL(string: "https://fonts.adobe.com/fonts/utopia")),
        Family(name: "Raleway", source: "Free (SIL Open Font License) from Google Fonts. Add the static weights.",
               link: URL(string: "https://fonts.google.com/specimen/Raleway")),
    ]

    static var missing: [FontFace] { faces.filter { !$0.installed } }

    /// The PostScript name to ask for: `name`, or the other name a face goes by ("Raleway" is "Raleway-Regular" in
    /// the Google Fonts release). Nil when neither is installed.
    static func resolve(_ name: String) -> String? {
        if NSFont(name: name, size: 12) != nil { return name }
        return faces.first { $0.names.contains(name) }?.names.first { $0 != name && NSFont(name: $0, size: 12) != nil }
    }

    /// Where fonts added in setup are kept; registered for Typeset only, at launch.
    static var userFontsDir: URL {
        let d = IssueStore.supportDir.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let fontExtensions: Set<String> = ["otf", "ttf", "ttc", "otc"]

    /// Copy font files (or every font in the folders given) into `userFontsDir` and register them.
    /// Returns how many were added and the names of any that couldn't be.
    static func add(_ urls: [URL]) -> (added: Int, failed: [String]) {
        let fm = FileManager.default
        var files: [URL] = []
        for u in urls {
            var dir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: nil)
                while let f = e?.nextObject() as? URL {
                    if fontExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if fontExtensions.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        var added = 0, failed: [String] = []
        for f in files {
            let dest = userFontsDir.appendingPathComponent(f.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    CTFontManagerUnregisterFontsForURL(dest as CFURL, .process, nil)
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: f, to: dest)
                if CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil) { added += 1 } else { failed.append(f.lastPathComponent) }
            } catch { failed.append(f.lastPathComponent) }
        }
        return (added, failed)
    }
}

// MARK: the app's view of it

/// What the setup window and the rest of the app watch: the paper's settings and which fonts are missing.
@Observable
final class Setup {
    static let shared = Setup()

    var paper: PaperSettings { didSet { if paper != oldValue { Paper.save(paper) } } }
    private(set) var missingFonts: [FontFace]
    /// Bumped when the nameplate changes, so views showing it redraw.
    private(set) var nameplateVersion = 0
    /// Set once fonts were added this session: what's on screen was set without them.
    private(set) var fontsAddedThisSession = false

    private init() {
        paper = Paper.settings
        missingFonts = FontCheck.missing
    }

    func recheckFonts() { missingFonts = FontCheck.missing }

    func addFonts(_ urls: [URL]) -> (added: Int, failed: [String]) {
        let r = FontCheck.add(urls)
        if r.added > 0 { fontsAddedThisSession = true }
        recheckFonts()
        return r
    }

    func setNameplate(_ url: URL?) throws {
        try Paper.setNameplate(url)
        nameplateVersion += 1
    }

    static let seenKey = "SetupSeen"
    /// Open setup on launch: the first time, when fonts are missing or the paper isn't set up. Never in a test run.
    var shouldOpenOnLaunch: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TYPESET_SETUP"] == "1" { return true }          // to look at it from a test run
        guard env["GALLEY_DATA_DIR"] == nil, !UserDefaults.standard.bool(forKey: Self.seenKey) else { return false }
        return !missingFonts.isEmpty || !Paper.isConfigured
    }
}

// MARK: the window

struct SetupView: View {
    @State private var setup = Setup.shared
    @State private var fontNote: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    fontsSection
                    Divider()
                    paperSection
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Change any of this later from Typeset › Set Up Typeset…")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { UserDefaults.standard.set(true, forKey: Setup.seenKey); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 680, idealHeight: 780)
        .onAppear { setup.recheckFonts() }
        .onDisappear { UserDefaults.standard.set(true, forKey: Setup.seenKey) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Wordmark(size: 34)
            Text("Typeset lays out a tabloid newspaper in a fixed house style. Two things to set up: the fonts, which " +
                 "decide how the pages look and fit, and your paper's details, which are optional and can be filled in as you go.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: fonts

    private var fontsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("1. Fonts").font(.title2.weight(.semibold))
                Spacer()
                if setup.missingFonts.isEmpty {
                    Label("All \(FontCheck.faces.count) faces found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("\(setup.missingFonts.count) of \(FontCheck.faces.count) missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Text("Typeset doesn't include these fonts; their licenses don't allow it. Fonts installed on this Mac, or " +
                 "active in Adobe Creative Cloud, are found on their own. Otherwise, add the font files here. Until then, " +
                 "pages are set in system fonts, so they won't match print and stories will fit differently.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(FontCheck.families) { fam in
                    familyRow(fam)
                    if fam.id != FontCheck.families.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Button("Add Font Files…") { chooseFonts() }
                Button("Show Fonts Folder") { NSWorkspace.shared.activateFileViewerSelecting([FontCheck.userFontsDir]) }
                Button("Check Again") { setup.recheckFonts() }
                Spacer()
            }
            if let fontNote {
                Text(fontNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if setup.fontsAddedThisSession {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Quit and reopen Typeset to set the pages in the new fonts.")
                    Button("Relaunch") { relaunch() }
                }
                .font(.callout)
            }
        }
    }

    private func familyRow(_ fam: FontCheck.Family) -> some View {
        let faces = FontCheck.faces.filter { $0.family == fam.name }
        let missing = Set(setup.missingFonts.map(\.id))
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: faces.allSatisfy { !missing.contains($0.id) } ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(faces.allSatisfy { !missing.contains($0.id) } ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fam.name).font(.headline)
                    if let link = fam.link { Link("Get it", destination: link).font(.callout) }
                }
                Text(fam.source).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(faces) { f in
                        Text(f.style)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(missing.contains(f.id) ? Color.orange.opacity(0.16) : Color.green.opacity(0.14)))
                            .foregroundStyle(missing.contains(f.id) ? Color.orange : Color.primary)
                            .help(missing.contains(f.id) ? "Missing: \(f.names.joined(separator: " or "))" : "Found")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func chooseFonts() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.font, .folder]
        panel.message = "Choose font files, or a folder of them"
        guard panel.runModal() == .OK else { return }
        let r = setup.addFonts(panel.urls)
        var note = r.added == 1 ? "Added 1 font." : "Added \(r.added) fonts."
        if !r.failed.isEmpty { note += " Couldn't add: \(r.failed.joined(separator: ", "))." }
        fontNote = note
    }

    private func relaunch() {
        UserDefaults.standard.set(true, forKey: Setup.seenKey)
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: the paper

    private var paperSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("2. Your paper").font(.title2.weight(.semibold))
                Text("Optional").font(.callout).foregroundStyle(.secondary)
            }
            Text("Skip any of this and fill it in when you need it. It's used for new issues; an issue already " +
                 "made keeps its own Header and Folio, which you can edit like any component.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            SwiftUI.Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("e.g. The Campus Chronicle", text: $setup.paper.name)
                }
                GridRow {
                    Text("Website")
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("e.g. news.example.edu", text: $setup.paper.website)
                        Text("Printed in each inside page's folio, and as \"\(Paper.onlineLine(for: setup.paper.website))\"")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow(alignment: .top) {
                    Text("Nameplate")
                    nameplateRow
                }
            }
            staffEditor
        }
    }

    private var nameplateRow: some View {
        let _ = setup.nameplateVersion
        let url = Paper.nameplateURL
        return VStack(alignment: .leading, spacing: 6) {
            if let url, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 80, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            } else {
                Text("None yet. The front page's Header leaves the space empty.").foregroundStyle(.secondary)
            }
            HStack {
                Button(url == nil ? "Choose…" : "Replace…") { chooseNameplate() }
                if Paper.userNameplate != nil { Button("Remove") { try? setup.setNameplate(nil) } }
            }
            Text("A PDF (best) or a picture, 729 × 118 pt: the width of the page inside its margins.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseNameplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Paper.nameplateTypes
        panel.message = "Choose your paper's nameplate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try setup.setNameplate(url) } catch { NSAlert(error: error).runModal() }
    }

    private var staffEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Staff").font(.headline)
                Text("Pick a byline from this list in the article editor; the title is filled in from the role.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach($setup.paper.staff.indices, id: \.self) { i in
                    HStack {
                        TextField("Name", text: $setup.paper.staff[i].name)
                        TextField("Role, e.g. News Editor", text: $setup.paper.staff[i].role)
                        Button { setup.paper.staff.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
            }
            Button { setup.paper.staff.append(StaffMember(name: "", role: "")) } label: {
                Label("Add Person", systemImage: "plus")
            }
        }
    }
}

extension Paper {
    static func onlineLine(for website: String) -> String {
        let h = host(of: website)
        return h.isEmpty ? "Read the rest online." : "Read the rest at \(h)."
    }
}

/// Typeset › Set Up Typeset…
struct SetupCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Set Up Typeset…") { openWindow(id: "setup") }
    }
}

/// In the window's toolbar while fonts are missing: what's wrong, and a way to fix it.
struct MissingFontsButton: View {
    @State private var setup = Setup.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if !setup.missingFonts.isEmpty {
            Button { openWindow(id: "setup") } label: {
                Label("\(setup.missingFonts.count) Fonts Missing", systemImage: "textformat.size")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
            }
            .help("Pages are set in system fonts until the house style's fonts are added. Click to set them up.")
        }
    }
}
