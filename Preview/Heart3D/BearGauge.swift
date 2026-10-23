// App-ready runtime part of the bear gauge: no SceneKit, only the exported PNG pair + manifest.
// This file is what would move into Tokenly; the preview sheets use it on the exported assets
// so the comparison images exercise the same code path the app would.
import CoreGraphics
import Foundation
import ImageIO

struct BearAssetSet {
    let empty: CGImage
    let full: CGImage
    /// Pixel rows (from the top) where the silhouette starts and ends; 0–100% maps onto this span.
    let fillTop: Int
    let fillBottom: Int
}

enum BearGaugeCompositor {
    /// Empty layer, then the full layer clipped below the live level (fractional row blended),
    /// then a thin surface highlight painted source-atop so it never leaves the silhouette.
    static func image(_ set: BearAssetSet, fraction: Double?, surfaceAlpha: CGFloat = 0.45) -> CGImage {
        let w = set.empty.width, h = set.empty.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .none
        ctx.draw(set.empty, in: bounds)
        let f = min(max(fraction ?? 0, 0), 1)
        guard f > 0 else { return ctx.makeImage()! }
        // Core Graphics counts rows from the bottom.
        let bottomFromBottom = CGFloat(h - set.fillBottom)
        let level = bottomFromBottom + CGFloat(f) * CGFloat(set.fillBottom - set.fillTop)
        let whole = floor(level)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(w), height: whole))
        ctx.draw(set.full, in: bounds)
        ctx.restoreGState()
        if level - whole > 0.01 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: whole, width: CGFloat(w), height: 1))
            ctx.setAlpha(level - whole)
            ctx.draw(set.full, in: bounds)
            ctx.restoreGState()
        }
        if f < 0.98 {
            let lineWidth = max(0.75, CGFloat(w) * 0.014)
            ctx.saveGState()
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: surfaceAlpha))
            ctx.fill(CGRect(x: 0, y: level - lineWidth / 2, width: CGFloat(w), height: lineWidth))
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    /// Loads `bear-<name>-{empty,full}@<scale>x.png` and the fill span from `bear-assets.json`.
    static func load(service: String, scale: Int, from folder: URL) -> BearAssetSet? {
        func png(_ layer: String) -> CGImage? {
            let url = folder.appendingPathComponent("bear-\(service)-\(layer)@\(scale)x.png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let empty = png("empty"), let full = png("full"),
              let data = try? Data(contentsOf: folder.appendingPathComponent("bear-assets.json")),
              let manifest = try? JSONDecoder().decode(BearManifest.self, from: data),
              let span = manifest.fillRows["\(scale)"] else { return nil }
        return BearAssetSet(empty: empty, full: full, fillTop: span[0], fillBottom: span[1])
    }
}

struct BearManifest: Codable {
    /// Point size of every layer (width, height).
    let pointSize: [Double]
    /// Scale → [top, bottom) silhouette rows in pixels.
    let fillRows: [String: [Int]]
    /// Where the face centre sits, in points from the frame's top-left, for placing the number.
    let numberCenter: [Double]
    /// Fraction (0–1, from the bottom) at which the fill covers the whole number: switch to light text above it.
    let numberCoveredAt: Double
    let services: [String]
    let layers: [String]
    let scales: [Int]
}
