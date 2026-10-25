// Extracts concept D from the concept board without redrawing anything.
//  1. original-crop.png  — exact board pixels, square 343×343 (x 1156…1498, y 104…446), byte-identical.
//  2. native-396.png     — transparent 396×396 canvas at the original pixel scale (no resampling):
//     plate pixels copied unchanged, alpha 1 inside the plate; outside it, the baked-in drop shadow is
//     separated from the board background (alpha = 1 − pixel / background, black shadow) so it works on
//     any desktop. The plate occupies 319/396 = 80.6% of the canvas (macOS grid: 824/1024 = 80.5%).
// The plate mask follows the plate's own 1-px edge line, traced on the board: straight edges at
// x 1168/1486, y 120/430; corners are circular arcs of radius 56 px — fitted to the edge positions traced
// along rays at 0–90° in all four corners (every traced point within 0.6 px of the arc). Pixel
// interpolation of the raw ray samples left visible facets at 1024 px, so the fitted arc is used.
// Usage: extract <board.png> <outdir>
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = CommandLine.arguments
let board = Raw(args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func writePNG(_ img: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest))
}

// MARK: 1. Exact crop
let cropRect = CGRect(x: 1156, y: 104, width: 343, height: 343)
let crop = board.image.cropping(to: cropRect)!
writePNG(crop, "original-crop-343.png")

// MARK: Plate mask (measured)
let px0 = 1168.0, px1 = 1486.0, py0 = 120.0, py1 = 430.0, cornerR = 56.0
/// Is board point (x, y) inside the plate? Edge-line pixel centres lie on the boundary curve offset by
/// half a pixel outward, so the edge line itself stays in the plate.
func insidePlate(_ x: Double, _ y: Double) -> Bool {
    if x < px0 || x > px1 + 1 || y < py0 || y > py1 + 1 { return false }
    let cxL = px0 + 0.5 + cornerR, cxR = px1 + 0.5 - cornerR, cyT = py0 + 0.5 + cornerR, cyB = py1 + 0.5 - cornerR
    let cx = x < cxL ? cxL : (x > cxR ? cxR : x), cy = y < cyT ? cyT : (y > cyB ? cyB : y)
    if cx == x || cy == y { return true }
    return ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() <= cornerR + 0.5
}
func coverage(_ bx: Int, _ by: Int) -> Double {
    var n = 0
    for sy in 0..<4 { for sx in 0..<4 where insidePlate(Double(bx) + (Double(sx) + 0.5) / 4, Double(by) + (Double(sy) + 0.5) / 4) { n += 1 } }
    return Double(n) / 16
}

// MARK: Board background behind the shadow: per column, the mean of the clean rows 104…109.
var bgCol = [Int: (Double, Double, Double)]()
for x in Int(cropRect.minX)...Int(cropRect.maxX - 1) {
    var s = (0.0, 0.0, 0.0)
    for y in 104...109 { let p = board.px(x, y); s.0 += Double(p.0); s.1 += Double(p.1); s.2 += Double(p.2) }
    bgCol[x] = (s.0 / 6, s.1 / 6, s.2 / 6)
}

// MARK: 2. Native canvas
let N = 396
let originX = 1327 - N / 2, originY = 275 - N / 2               // plate centre (1327, 275) → canvas centre
var pix = [UInt8](repeating: 0, count: N * N * 4)               // premultiplied RGBA
var plateIdentical = 0, plateTotal = 0
for cy in 0..<N {
    for cx in 0..<N {
        let bx = originX + cx, by = originY + cy
        guard cropRect.contains(CGPoint(x: Double(bx) + 0.5, y: Double(by) + 0.5)) else { continue }
        let p = board.px(bx, by)
        let cov = coverage(bx, by)
        // Shadow alpha from darkening against the local background (black shadow).
        let bg = bgCol[bx]!
        let lum = Double(p.0 + p.1 + p.2) / 3, bgl = (bg.0 + bg.1 + bg.2) / 3
        var sa = max(0, 1 - lum / bgl)
        if sa < 0.006 { sa = 0 }
        // Fade the residual shadow out over the last 6 px of the crop so no square edge can show.
        let edgeDist = Double(min(bx - Int(cropRect.minX), Int(cropRect.maxX) - 1 - bx, by - Int(cropRect.minY), Int(cropRect.maxY) - 1 - by))
        sa *= min(1, edgeDist / 6)
        // Composite: plate (opaque original pixel) over shadow by coverage.
        let a = cov + (1 - cov) * sa
        let o = (cy * N + cx) * 4
        pix[o] = UInt8((Double(p.0) * cov).rounded()); pix[o + 1] = UInt8((Double(p.1) * cov).rounded())
        pix[o + 2] = UInt8((Double(p.2) * cov).rounded()); pix[o + 3] = UInt8((a * 255).rounded())
        if cov == 1 { plateTotal += 1; plateIdentical += 1 }
    }
}
let native = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: N * 4,
                     space: board.image.colorSpace!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: CGDataProvider(data: Data(pix) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
writePNG(native, "native-396.png")
print("crop", Int(cropRect.width), "x", Int(cropRect.height), "| native canvas", N, "| fully-inside plate pixels", plateTotal,
      "| plate fraction", String(format: "%.4f", 319.0 / Double(N)))
