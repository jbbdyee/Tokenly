import AppKit
import ImageIO
import SwiftUI

// Glass jelly bear gauge for the menu bar. The look comes from pre-rendered 3D layers
// (Resources/BearGauge, produced by Preview/Heart3D/run-bear-b.sh: 21pt frame, ears ×1.05);
// nothing here redraws the bear. Each service has an "empty" and a "full" layer of the same lit
// model, blended at the live level. Digits, names and the outline are added by MenuBarGaugeRow.

struct BearAssetSet {
    let empty: CGImage
    let full: CGImage
    /// Pixel rows (from the top) where the silhouette starts and ends; 0–100% maps onto this span.
    let fillTop: Int
    let fillBottom: Int
}

struct BearManifest: Codable {
    struct Frame: Codable {
        let width: Double, height: Double
        /// Silhouette rows [top, bottom) in pixels; 0–100% maps onto this span, `fillBottom` is the chin.
        let fillTop: Int, fillBottom: Int
        /// Face centre above the name, in points from the frame's top-left; the digits are centred here.
        let numberCenterY: Double
    }
    let version: Int
    let earScale: Double
    /// Scale ("2", "3") → frame layout.
    let frames: [String: Frame]
    /// Level (0–1) at which the fill covers the whole number.
    let numberCoveredAt: Double
    let services: [String]
    let layers: [String]
}

enum BearGaugeCompositor {
    /// Empty layer, then the full layer clipped below the live level (the boundary row blended by its
    /// fractional coverage), then a thin surface highlight painted source-atop so it stays inside the bear.
    static func image(_ set: BearAssetSet, fraction: Double?) -> CGImage? {
        let width = set.empty.width, height = set.empty.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.interpolationQuality = .none
        ctx.draw(set.empty, in: bounds)
        let f = min(max(fraction ?? 0, 0), 1)
        guard f > 0 else { return ctx.makeImage() }
        // Core Graphics counts rows from the bottom.
        let level = CGFloat(height - set.fillBottom) + CGFloat(f) * CGFloat(set.fillBottom - set.fillTop)
        let whole = floor(level)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: whole))
        ctx.draw(set.full, in: bounds)
        ctx.restoreGState()
        if level - whole > 0.01 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: whole, width: CGFloat(width), height: 1))
            ctx.setAlpha(level - whole)
            ctx.draw(set.full, in: bounds)
            ctx.restoreGState()
        }
        if f < 0.98 {
            let lineWidth = max(0.75, CGFloat(width) * 0.014)
            ctx.saveGState()
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45))
            ctx.fill(CGRect(x: 0, y: level - lineWidth / 2, width: CGFloat(width), height: lineWidth))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

/// Loads the bundled layers once per (service, scale).
@MainActor
enum BearAssets {
    static let folder = Bundle.main.resourceURL?.appendingPathComponent("BearGauge")
    static let manifest: BearManifest? = {
        guard let url = folder?.appendingPathComponent("bear-assets.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BearManifest.self, from: data)
    }()
    private static var cache: [String: BearAssetSet] = [:]

    /// `service` is codex, claude, antigravity or stale; scale is 2 or 3.
    static func set(service: String, scale: Int) -> BearAssetSet? {
        let key = "\(service)@\(scale)"
        if let hit = cache[key] { return hit }
        guard let folder, let frame = frame(scale: scale) else { return nil }
        func png(_ layer: String) -> CGImage? {
            let url = folder.appendingPathComponent("bear-\(service)-\(layer)@\(scale)x.png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let empty = png("empty"), let full = png("full") else { return nil }
        let set = BearAssetSet(empty: empty, full: full, fillTop: frame.fillTop, fillBottom: frame.fillBottom)
        cache[key] = set
        return set
    }

    static func frame(scale: Int) -> BearManifest.Frame? { manifest?.frames["\(scale)"] }

    static func service(for provider: HeartGaugeProvider, stale: Bool) -> String {
        stale ? "stale" : provider.rawValue
    }
}

struct MenuBarBearItem {
    /// nil = no data: empty bear with "?".
    let percent: Double?
    let name: String
    let service: String
}

enum MenuBarBearImage {
    /// 21pt bears with the service name set into the chin outline (option B of Preview/Heart3D/50).
    static let frameWidth: CGFloat = 21
    static let digitSize: CGFloat = 9.3
    static let wideDigitSize: CGFloat = 7.2

    /// The gauge icons for a row; also used by tests to check digits and names per bear.
    @MainActor
    static func icons(_ items: [MenuBarBearItem], scale: Int) -> [GaugeIcon]? {
        guard let frame = BearAssets.frame(scale: scale) else { return nil }
        let earTop = CGFloat(frame.fillTop) / CGFloat(scale), chin = CGFloat(frame.fillBottom) / CGFloat(scale)
        // Centre ear ring (0.5pt above the ears) to name bottom vertically in the 22pt row.
        let top = MenuBarGaugeRow.snap((MenuBarGaugeRow.height - (chin + MenuBarGaugeRow.nameHalfHeight - (earTop - 0.5))) / 2
                                       - (earTop - 0.5), scale: scale)
        var icons: [GaugeIcon] = []
        for item in items {
            guard let set = BearAssets.set(service: item.service, scale: scale),
                  let body = BearGaugeCompositor.image(set, fraction: item.percent.map { min(max($0, 0), 100) / 100 })
            else { return nil }
            let text = GaugeDigits.text(item.percent)
            icons.append(GaugeIcon(body: body, bodyFrame: CGRect(x: 0, y: top, width: frameWidth,
                                                                  height: CGFloat(body.height) / CGFloat(scale)),
                                   numberCenter: CGPoint(x: frameWidth / 2, y: top + CGFloat(frame.numberCenterY)),
                                   nameCenterY: top + chin,
                                   text: text, digitSize: text.count >= 3 ? wideDigitSize : digitSize,
                                   style: style(item), name: item.name, outlineTone: item.service))
        }
        return icons
    }

    /// Dark ink with a white hairline, or white on Claude's darker fill once it covers the number
    /// (white on the yellow/ice-blue fills was too faint at menu bar size).
    @MainActor
    static func style(_ item: MenuBarBearItem) -> GaugeDigits.Style {
        let coveredAt = BearAssets.manifest?.numberCoveredAt ?? 0.78
        if item.service == "claude", (item.percent ?? 0) / 100 >= coveredAt {
            return GaugeDigits.Style(fill: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                     outline: CGColor(srgbRed: 0x5A / 255, green: 0x3F / 255, blue: 0xB8 / 255, alpha: 0.9))
        }
        let ink: (CGFloat, CGFloat, CGFloat) = switch item.service {
        case "codex": (0x7A, 0x52, 0x08)
        case "claude": (0x3E, 0x2C, 0x7C)
        case "antigravity": (0x15, 0x4A, 0x66)
        default: (0x45, 0x45, 0x4B)
        }
        return GaugeDigits.Style(fill: CGColor(srgbRed: ink.0 / 255, green: ink.1 / 255, blue: ink.2 / 255, alpha: 1),
                                 outline: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    }

    @MainActor
    static func make(_ items: [MenuBarBearItem], dark: Bool) -> NSImage? {
        let scale = MenuBarGaugeRow.scale
        guard let icons = icons(items, scale: scale),
              let image = MenuBarGaugeRow.render(icons, columnWidth: frameWidth, scale: scale, dark: dark, strongOutline: true)
        else { return nil }
        let result = NSImage(cgImage: image, size: MenuBarGaugeRow.size(count: items.count, columnWidth: frameWidth))
        result.isTemplate = false
        return result
    }
}

/// Silhouette outline chosen from the Preview/Heart3D/30 study ("강함"): a translucent dark ring just
/// outside each bear's alpha, tinted with its hue, plus a faint light line just inside beside the glass
/// rim. Applied to the whole row bitmap rather than baked into the PNGs, because the bear assets leave
/// only 1px (2x) or 0px (1x) of margin and a baked ring would be clipped at the frame edge.
enum BearOutline {
    static let outerOpacity: Float = 0.62
    static let innerOpacity: Float = 0.20

    private static let tones: [String: SIMD3<Float>] = [
        "codex": SIMD3(0.36, 0.25, 0.04), "claude": SIMD3(0.20, 0.14, 0.40),
        "antigravity": SIMD3(0.09, 0.27, 0.38), "stale": SIMD3(0.24, 0.24, 0.27)
    ]

    /// `rows` limits the silhouette to the top rows (nil = the whole image, used once names are drawn later).
    static func apply(to image: CGImage, scale: Int, services: [String], rows: Int? = nil) -> CGImage {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px = bytes.map { Float($0) / 255 }

        // The ring may reach one row below the limit; text drawn later never counts.
        let bearRows = min(h, rows ?? h)
        let band = min(h, bearRows + 1)
        var mask = [Float](repeating: 0, count: w * h)
        for y in 0..<bearRows {
            for x in 0..<w { mask[y * w + x] = max(0, min(1, (px[(y * w + x) * 4 + 3] - 0.06) / 0.4)) }
        }
        func m(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= band) ? 0 : mask[y * w + x] }

        // Which bear a column belongs to: runs of occupied columns, left to right (the spacing separates them).
        var owner = [Int](repeating: 0, count: w)
        var runs: [(start: Int, end: Int)] = []
        for x in 0..<w where (0..<bearRows).contains(where: { mask[$0 * w + x] > 0 }) {
            if let last = runs.last, x <= last.end + 1 { runs[runs.count - 1].end = x } else { runs.append((x, x)) }
        }
        for x in 0..<w {
            let nearest = runs.indices.min { a, b in
                distance(x, runs[a]) < distance(x, runs[b])
            } ?? 0
            owner[x] = min(nearest, max(0, services.count - 1))
        }

        // ~0.5pt disc: at 2x the exact kernel of the approved study (edges 1, diagonals 0.75).
        let kernel: [(Int, Int, Float)] = scale <= 2
            ? [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1), (-1, -1, 0.75), (1, -1, 0.75), (-1, 1, 0.75), (1, 1, 0.75)]
            : [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1), (-1, -1, 1), (1, -1, 1), (-1, 1, 1), (1, 1, 1),
               (-2, 0, 0.5), (2, 0, 0.5), (0, -2, 0.5), (0, 2, 0.5)]
        var out = px
        for y in 0..<band {
            for x in 0..<w {
                let here = m(x, y)
                var grown = here, shrunk = here
                for (dx, dy, weight) in kernel {
                    let v = m(x + dx, y + dy)
                    grown = max(grown, v * weight)
                    shrunk = min(shrunk, 1 - (1 - v) * weight)
                }
                let i = (y * w + x) * 4
                let ring = max(0, grown - here) * outerOpacity
                if ring > 0 {
                    // Painted behind the existing pixel so the glass edge stays on top.
                    let tone = services.isEmpty ? SIMD3<Float>(0.2, 0.2, 0.2) : (tones[services[owner[x]]] ?? SIMD3(0.2, 0.2, 0.2))
                    let behind = 1 - px[i + 3]
                    for k in 0..<3 { out[i + k] += tone[k] * ring * behind }
                    out[i + 3] += ring * behind
                }
                let edge = max(0, here - shrunk) * innerOpacity
                if edge > 0 {
                    let a = out[i + 3]
                    for k in 0..<3 { out[i + k] += (a - out[i + k]) * edge }
                }
            }
        }
        let result = out.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        guard let provider = CGDataProvider(data: Data(result) as CFData),
              let outlined = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false,
                                     intent: .defaultIntent) else { return image }
        return outlined
    }

    private static func distance(_ x: Int, _ run: (start: Int, end: Int)) -> Int {
        x < run.start ? run.start - x : (x > run.end ? x - run.end : 0)
    }
}
