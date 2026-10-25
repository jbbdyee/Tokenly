// recomp: composite native-396 over the board background (per-column bg from rows 104…109) and diff
// against the original crop; prints the error histogram and the worst pixels, writes a ×3 diff heat map.
import AppKit
let b = Raw(CommandLine.arguments[1]), n = Raw(CommandLine.arguments[2])
let straight = n.image.alphaInfo == .last || n.image.alphaInfo == .first
print("native alphaInfo", n.image.alphaInfo.rawValue, straight ? "(straight)" : "(premultiplied)")
var hist = [Int](repeating: 0, count: 6), worst: [(Int, Int, Int)] = []
let W = 343
var heat = [UInt8](repeating: 0, count: W * W * 4)
for y in 0..<W { for x in 0..<W {
    let bx = 1156 + x, by = 104 + y
    var bg = (0.0, 0.0, 0.0)
    for yy in 104...109 { let p = b.px(bx, yy); bg.0 += Double(p.0) / 6; bg.1 += Double(p.1) / 6; bg.2 += Double(p.2) / 6 }
    let cx = bx - 1129, cy = by - 77
    let o = cy * n.bpr + cx * n.bpp
    let a = Double(n.data[o + 3]) / 255
    // PNG decodes as straight (non-premultiplied) alpha: premultiply before compositing.
    let k = straight ? a : 1
    let c = (Double(n.data[o]) * k + bg.0 * (1 - a), Double(n.data[o + 1]) * k + bg.1 * (1 - a), Double(n.data[o + 2]) * k + bg.2 * (1 - a))
    let p = b.px(bx, by)
    let d = Int(max(abs(c.0 - Double(p.0)), abs(c.1 - Double(p.1)), abs(c.2 - Double(p.2))).rounded())
    hist[min(5, d)] += 1
    if d >= 4 { worst.append((d, x, y)) }
    let ho = (y * W + x) * 4; let v = UInt8(min(255, d * 40))
    heat[ho] = v; heat[ho + 1] = 0; heat[ho + 2] = 0; heat[ho + 3] = 255
} }
print("Δ histogram (0,1,2,3,4,≥5):", hist)
worst.sort { $0.0 > $1.0 }
print("worst:", worst.prefix(12).map { "Δ\($0.0)@(\($0.1),\($0.2))" }.joined(separator: " "))
let img = CGImage(width: W, height: W, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(heat) as CFData)!,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let ctx = CGContext(data: nil, width: W * 2, height: W * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .none; ctx.draw(img, in: CGRect(x: 0, y: 0, width: W * 2, height: W * 2))
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
