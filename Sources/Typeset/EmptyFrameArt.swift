import AppKit

/// What an empty frame shows on screen (phase 5), never in print: an image or ad frame is filled with the icon's
/// rainbow, diagonally, the gradient behind the app icon's letters (`tools/make_resources.py icon`); a text frame
/// gets stacked wavy rainbow lines, after Material's wavy progress bar, the way people scribble a few wavy lines
/// on paper to mean "text goes here". The lines are sized by the frame's type: fat for a headline, thin and
/// many for body.
enum EmptyFrameArt {
    /// The icon's rainbow, left to right.
    static let rainbow: [NSColor] = [(255, 59, 48), (255, 149, 0), (255, 204, 0), (52, 199, 89), (10, 132, 255), (175, 82, 222)]
        .map { NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }
    static let gradient = NSGradient(colors: rainbow)!

    /// How a text frame's lines are drawn: the stroke, the distance between lines, and how far each wave rises.
    struct Lines { var stroke: CGFloat; var pitch: CGFloat; var amplitude: CGFloat; var wavelength: CGFloat }

    static func lines(for type: FrameType) -> Lines {
        switch type {
        case .headline: Lines(stroke: 6, pitch: 22, amplitude: 3, wavelength: 26)
        case .teaserHeadline, .pullQuote: Lines(stroke: 4, pitch: 16, amplitude: 2.5, wavelength: 20)
        case .kicker, .author, .teaserPage: Lines(stroke: 3, pitch: 13, amplitude: 1.8, wavelength: 16)
        case .authorTitle, .caption, .credit: Lines(stroke: 1.8, pitch: 9, amplitude: 1.3, wavelength: 12)
        default: Lines(stroke: 1.4, pitch: 7, amplitude: 1, wavelength: 10)            // body, whole story
        }
    }

    static func isPicture(_ type: FrameType) -> Bool { type == .image || type == .ad }

    /// Draws into the current (flipped) context.
    static func draw(_ type: FrameType, in r: CGRect) {
        guard r.width > 1, r.height > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if isPicture(type) {
            NSBezierPath(rect: r).addClip()
            gradient.draw(in: r, angle: -35)                                     // diagonal, as behind the icon's letters
            return
        }
        let l = lines(for: type)
        let path = wavyLines(in: r, l)
        guard !path.isEmpty else { return }
        ctx.addPath(path)
        ctx.setLineWidth(l.stroke)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        gradient.draw(in: r, angle: -35)
    }

    /// The wavy lines a text frame shows: one per `pitch`, the last one shorter, like the end of a paragraph.
    static func wavyLines(in r: CGRect, _ l: Lines) -> CGPath {
        let path = CGMutablePath()
        let inset = l.stroke / 2 + l.amplitude
        let n = max(1, Int((r.height - 2 * inset) / l.pitch) + 1)
        let left = r.minX + l.stroke / 2, full = max(0, r.width - l.stroke)
        for k in 0..<n {
            let y = n == 1 ? r.midY : r.minY + inset + CGFloat(k) * l.pitch
            guard y <= r.maxY - inset + 0.01 || n == 1 else { break }
            let w = k == n - 1 && n > 1 ? full * 0.6 : full
            guard w > 2 else { continue }
            var x: CGFloat = 0
            path.move(to: CGPoint(x: left, y: y))
            while x < w {
                x = min(w, x + 1)
                path.addLine(to: CGPoint(x: left + x, y: y + l.amplitude * sin(x / l.wavelength * 2 * .pi)))
            }
        }
        return path
    }
}
