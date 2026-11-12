// pngdiff a.png b.png diff.png — prints the number of pixels that differ (any channel by more than 8) and writes
// a diff image: unchanged pixels faded, changed ones red.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func load(_ p: String) -> (Int, Int, [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}
let a = CommandLine.arguments
guard a.count >= 3, let (w1, h1, p1) = load(a[1]), let (w2, h2, p2) = load(a[2]) else { print("unreadable"); exit(2) }
if w1 != w2 || h1 != h2 { print("size \(w1)x\(h1) vs \(w2)x\(h2)"); exit(1) }
var out = [UInt8](repeating: 255, count: w1 * h1 * 4)
var n = 0
for i in stride(from: 0, to: p1.count, by: 4) {
    let d = (0..<3).map { abs(Int(p1[i + $0]) - Int(p2[i + $0])) }.max()!
    if d > 8 { n += 1; out[i] = 255; out[i + 1] = 0; out[i + 2] = 0 }
    else { let g = UInt8(200 + Int(p1[i]) * 55 / 255); out[i] = g; out[i + 1] = g; out[i + 2] = g }
}
print(n)
if a.count >= 4 {
    let ctx = CGContext(data: &out, width: w1, height: h1, bitsPerComponent: 8, bytesPerRow: w1 * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
}
exit(n == 0 ? 0 : 1)
