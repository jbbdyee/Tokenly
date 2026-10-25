// finalize <master-2048.png> <outdir> : adds a soft icon shadow, then writes
// icon-1024/512/128/64/32/16.png by progressive Lanczos reduction from the 2048 master.
import AppKit
import CoreImage

let a = CommandLine.arguments
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: srgb])
var r = CGRect.zero
let master = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: &r, context: nil, hints: nil)!
let out = URL(fileURLWithPath: a[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let S = master.width
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Soft, low-contrast plate shadow (the reference plates float with a faint diffuse shadow).
ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(S) * 0.012), blur: CGFloat(S) * 0.03,
              color: NSColor(srgbRed: 0.25, green: 0.24, blue: 0.4, alpha: 0.16).cgColor)
ctx.draw(master, in: CGRect(x: 0, y: 0, width: S, height: S))
let withShadow = ctx.makeImage()!

func reduce(_ img: CGImage, to px: Int) -> CGImage {
    var cur = CIImage(cgImage: img), w = CGFloat(img.width)
    while w / 2 >= CGFloat(px) * 1.5 {       // halve until within 1.5× of the target
        cur = cur.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1])
        w /= 2
    }
    cur = cur.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(px) / w, kCIInputAspectRatioKey: 1])
    return ci.createCGImage(cur, from: CGRect(x: 0, y: 0, width: px, height: px), format: .RGBA8, colorSpace: srgb)!
}
for px in [1024, 512, 128, 64, 32, 16] {
    let img = reduce(withShadow, to: px)
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("icon-\(px).png"))
}
print("wrote", out.path)
