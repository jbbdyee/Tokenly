// resample <native-396.png> <outdir> : builds the icon sizes from the native canvas.
//  • 1024 and 512 are UPSCALES (×2.586, ×1.293) — no detail is added; method comparison written for 1024.
//  • 256…16 are downscales (progressive Lanczos, halving while the ratio is > 2).
// Colour management is disabled (working/output colour space = none), so values are only interpolated.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = Raw(a[1])
let out = URL(fileURLWithPath: a[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let input = CIImage(cgImage: src.image, options: [.colorSpace: NSNull()])
let N = CGFloat(src.w)

func write(_ img: CGImage, _ path: URL) {
    let d = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); precondition(CGImageDestinationFinalize(d))
}
func render(_ img: CIImage, _ px: Int) -> CGImage {
    ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: px, height: px), format: .RGBA8, colorSpace: nil)!
        .copy(colorSpace: srgb)!          // tag only (values untouched), matching the board's assumed sRGB
}
func lanczos(_ img: CIImage, _ s: CGFloat) -> CIImage {
    img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
}
func bicubic(_ img: CIImage, _ s: CGFloat) -> CIImage {
    // Catmull-Rom-like (B = 0, C = 0.75 is CI's default sharpness); no extra sharpening.
    img.applyingFilter("CIBicubicScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1, "inputB": 0.0, "inputC": 0.5])
}
func cgScale(_ px: Int, _ q: CGInterpolationQuality) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = q
    ctx.draw(src.image.copy(colorSpace: srgb)!, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

// Method comparison at 1024 (upscale).
let s1024 = 1024 / N
let methods: [(String, CGImage)] = [
    ("nearest", cgScale(1024, .none)),
    ("bilinear", cgScale(1024, .low)),
    ("bicubic-catmullrom", render(bicubic(input, s1024), 1024)),
    ("lanczos", render(lanczos(input, s1024), 1024)),
]
let cmpDir = out.appendingPathComponent("resampling-comparison")
try? FileManager.default.createDirectory(at: cmpDir, withIntermediateDirectories: true)
for (name, img) in methods { write(img, cmpDir.appendingPathComponent("1024-\(name).png")) }

// Overshoot (ringing) check: fraction of opaque output pixels whose channel leaves the [min, max] of the
// 2×2 source neighbourhood they interpolate from, and the largest excursion.
let srcPx = src
func overshoot(_ img: CGImage) -> (Double, Int) {
    let r = Raw(fromImage: img)
    var n = 0, bad = 0, worst = 0
    for y in stride(from: 0, to: 1024, by: 2) { for x in stride(from: 0, to: 1024, by: 2) {
        let o = y * r.bpr + x * r.bpp; if r.data[o + 3] < 255 { continue }
        let sx = (Double(x) + 0.5) / s1024 - 0.5, sy = (Double(y) + 0.5) / s1024 - 0.5
        let x0 = max(0, min(srcPx.w - 2, Int(sx))), y0 = max(0, min(srcPx.h - 2, Int(sy)))
        var lo = [255, 255, 255], hi = [0, 0, 0], opaque = true
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let so = (y0 + dy) * srcPx.bpr + (x0 + dx) * srcPx.bpp
            if srcPx.data[so + 3] < 255 { opaque = false }
            for c in 0..<3 { let v = Int(srcPx.data[so + c]); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v) }
        }
        if !opaque { continue }
        n += 1
        var e = 0
        for c in 0..<3 { let v = Int(r.data[o + c]); e = max(e, lo[c] - v, v - hi[c]) }
        if e > 1 { bad += 1 }; worst = max(worst, e)
    } }
    return (Double(bad) / Double(max(n, 1)), worst)
}
for (name, img) in methods {
    let (f, w) = overshoot(img)
    print(name.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: "overshoot >1 level: %5.2f%% of opaque samples, max %d", f * 100, w))
}

// Final sizes. 1024 / 512: Lanczos upscale (chosen after the comparison). 256…16: progressive Lanczos down.
func down(_ px: Int) -> CGImage {
    var cur = input, w = N
    while w / 2 >= CGFloat(px) * 1.5 { cur = lanczos(cur, 0.5); w = (w / 2).rounded(.down) }
    return render(lanczos(cur, CGFloat(px) / w), px)
}
let method = a.count > 3 ? a[3] : "lanczos"
for px in [1024, 512, 256, 128, 64, 32, 16] {
    let img: CGImage
    if px > Int(N) {
        img = method == "bicubic" ? render(bicubic(input, CGFloat(px) / N), px) : render(lanczos(input, CGFloat(px) / N), px)
    } else { img = down(px) }
    write(img, out.appendingPathComponent("icon-\(px).png"))
}
print("sizes written with", method, "for upscales")
