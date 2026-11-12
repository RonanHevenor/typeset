import Foundation

// the paper's faces first, before any text is set anywhere (the copyfit lanes start as soon as the window does)
FontLoader.registerBundledFonts()

if CommandLine.arguments.contains("--snapshot") {
    exit(MainActor.assumeIsolated { Snapshot.run(Array(CommandLine.arguments.dropFirst())) })
}
if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}
if let i = CommandLine.arguments.firstIndex(of: "--fetch"), CommandLine.arguments.count > i + 1 {
    // `Typeset --fetch <poly.rpi.edu link or headline>`: what Add from Link or Update reads, photos not downloaded
    let link = CommandLine.arguments[i + 1]
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task.detached {
        do {
            var slug = PolyWeb.slug(in: link)
            if slug == nil { slug = try await PolyWeb.slug(forHeadline: link) }
            guard let slug else { throw PolyWeb.Failure.notFound("A story with that headline") }
            let s = try await PolyWeb.story(slug: slug)
            print("page      \(s.page.absoluteString)\ndesk      \(s.desk.rawValue)\nkicker    \(s.kicker)\nheadline  \(s.headline)")
            print("byline    \(s.author) — \(s.authorTitle)\nbody      \(s.body.count) paragraphs, \(s.body.joined(separator: " ").split(separator: " ").count) words")
            for p in s.photos { print("photo     \(p.filename) | \(p.caption) | \(p.credit)") }
        } catch { print("error     \(error.localizedDescription)"); status = 1 }
        done.signal()
    }
    done.wait()
    exit(status)
}
if CommandLine.arguments.contains("--render") || CommandLine.arguments.contains("--make-components") {
    exit(Headless.run(Array(CommandLine.arguments.dropFirst())))
}
TypesetApp.main()
