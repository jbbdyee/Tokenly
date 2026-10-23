// Option B study: service name set into the bear's lower outline, bear and digits enlarged within the
// same 89 × 22pt row, ears 5% larger (re-rendered in SceneKit). Option A is the app's current
// MenuBarBearImage output, unchanged. Preview-only; compiled with the app's sources read-only.
// Run ./run-name-outline.sh.
import AppKit
import CoreImage
import SwiftUI

// MARK: - Geometry (points)

/// Row width stays the current 89pt: 1 + 3 × 21 + 2 × 12 + 1. Width, not the 22pt height, caps the bear.
let bWidth: CGFloat = 21
let bSpacing: CGFloat = 12
let rowSize = CGSize(width: 89, height: 22)
let scale = 2
let earScale: CGFloat = 1.05

// MARK: - B layers: SceneKit re-render with 5% larger ears, ×8 supersampled, Lanczos to 42px wide

@MainActor
enum BLayers {
    static let renderer = BearRenderer(earScale: earScale)
    static let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    static var cache: [String: BearAssetSet] = [:]

    static func layer(_ color: BearColor, filled: Bool) -> CGImage {
        let px = Int(bWidth) * scale
        let source = renderer.render(color: color, filled: filled, pixelWidth: px * 8)
        let s = CGFloat(px) / CGFloat(source.width)
        let height = Int((CGFloat(source.height) * s).rounded())
        let out = CIImage(cgImage: source).applyingFilter("CILanczosScaleTransform",
                                                           parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        return ci.createCGImage(out, from: CGRect(x: 0, y: 0, width: px, height: height),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    static func set(_ service: String) -> BearAssetSet {
        if let hit = cache[service] { return hit }
        let color = BearColor(rawValue: service)!
        let empty = layer(color, filled: false), full = layer(color, filled: true)
        let rows = silhouetteRows(empty)
        let set = BearAssetSet(empty: empty, full: full, fillTop: rows.top, fillBottom: rows.bottom)
        cache[service] = set
        return set
    }
}

func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

func silhouetteRows(_ image: CGImage) -> (top: Int, bottom: Int) {
    let b = rgba(image)
    var top = image.height, bottom = 0
    for y in 0..<image.height where (0..<image.width).contains(where: { b[(y * image.width + $0) * 4 + 3] > 127 }) {
        top = min(top, y); bottom = max(bottom, y + 1)
    }
    return (top, bottom)
}

// MARK: - Text

func roundedFont(_ size: CGFloat) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
}

func ctLine(_ text: String, _ font: CTFont, _ color: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]) as CFAttributedString)
}

/// Digit sizes scale with the bear (21/18); the 3-digit size is then trimmed until "100" keeps 2px clear.
let digitScale = bWidth / 18
let bDigitSize = 8.0 * digitScale
let bWideDigitSize = 6.2 * digitScale

/// Same colour rule as the app: Claude gets white digits once its fill covers them.
@MainActor
func numberStyle(_ item: MenuBarBearItem) -> BearNumber.Style { BearNumber.style(item) }

// MARK: - Row composition (Core Graphics, y-up, in points × scale)

struct BLayout {
    /// Bear frame origin (points, from the row's top-left) and the derived anchors.
    let frameTop: CGFloat
    let chinY: CGFloat        // silhouette bottom edge, from the row top
    let earTopY: CGFloat
    let numberCenterY: CGFloat
}

@MainActor
func layout() -> BLayout {
    let set = BLayers.set("codex")
    let frameH = CGFloat(set.empty.height) / CGFloat(scale)
    let earTop = CGFloat(set.fillTop) / CGFloat(scale), chin = CGFloat(set.fillBottom) / CGFloat(scale)
    // Name glyphs (cap height ≈ 4.4pt) are centred on the chin edge; content spans ear ring → name bottom.
    let nameHalf: CGFloat = 4.38 / 2
    let contentTop = earTop - 0.5, contentBottom = chin + nameHalf
    let frameTop = ((rowSize.height - (contentBottom - contentTop)) / 2 - contentTop) * 2 / 2
    let snappedTop = (frameTop * CGFloat(scale)).rounded() / CGFloat(scale)
    // Number: centred between the face top (unit 0.105 of the outline) and the top of the name knockout.
    let unitsPerPoint = 1.04 / bWidth
    let faceTop = earTop + (0.105 - (0.15 - 0.085 * earScale)) / unitsPerPoint
    let nameTop = chin - nameHalf - 0.75
    return BLayout(frameTop: snappedTop, chinY: snappedTop + chin, earTopY: snappedTop + earTop,
                   numberCenterY: snappedTop + (faceTop + nameTop) / 2)
}

@MainActor
func bRow(_ items: [MenuBarBearItem], dark: Bool) -> CGImage {
    let L = layout()
    let w = Int(rowSize.width) * scale, h = Int(rowSize.height) * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.setShouldSmoothFonts(false)
    func snap(_ v: CGFloat) -> CGFloat { (v * CGFloat(scale)).rounded() / CGFloat(scale) }
    var nameDraws: [(CTLine, CGPoint)] = []
    for (index, item) in items.enumerated() {
        let x = 1 + CGFloat(index) * (bWidth + bSpacing)
        let set = BLayers.set(item.service)
        let gauge = BearGaugeCompositor.image(set, fraction: item.percent.map { $0 / 100 })!
        let frameH = CGFloat(gauge.height) / CGFloat(scale)
        ctx.draw(gauge, in: CGRect(x: x, y: rowSize.height - L.frameTop - frameH, width: bWidth, height: frameH))
        // Digits: glyph ink box centred on the face above the name.
        let text = BearNumber.text(item.percent)
        let font = roundedFont(text.count >= 3 ? bWideDigitSize : bDigitSize)
        let style = numberStyle(item)
        let ink = CTLineGetBoundsWithOptions(ctLine(text, font, style.fill), .useGlyphPathBounds)
        let origin = CGPoint(x: snap(x + bWidth / 2 - ink.midX), y: snap(rowSize.height - L.numberCenterY - ink.midY))
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            ctx.textPosition = CGPoint(x: origin.x + CGFloat(cos(a)) * 0.35, y: origin.y + CGFloat(sin(a)) * 0.35)
            CTLineDraw(ctLine(text, font, style.outline), ctx)
        }
        ctx.textPosition = origin
        CTLineDraw(ctLine(text, font, style.fill), ctx)
        // Name: same 6pt heavy as today, black/white by bar appearance, centred on the chin edge.
        let nameColor = dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let nameLine = ctLine(item.name, roundedFont(6), nameColor)
        let nameInk = CTLineGetBoundsWithOptions(nameLine, .useGlyphPathBounds)
        nameDraws.append((nameLine, CGPoint(x: snap(x + bWidth / 2 - nameInk.midX), y: snap(rowSize.height - L.chinY - nameInk.midY))))
    }
    // Strong outline on the bears only (names not drawn yet), same algorithm and opacities as the app.
    var px = rgba(ctx.makeImage()!).map { Float($0) / 255 }
    px = strongOutline(px, w: w, h: h, services: items.map(\.service))
    // Name knockout: clear bear + outline within 1.5px of the name glyphs, so the name breaks the outline.
    let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    mask.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    for (line, origin) in nameDraws { mask.textPosition = origin; CTLineDraw(line, mask) }
    let nameAlpha = rgba(mask.makeImage()!).enumerated().filter { $0.offset % 4 == 3 }.map { Float($0.element) / 255 }
    let halo: Float = 1.5
    for y in 0..<h {
        for x in 0..<w {
            var k: Float = 0
            for dy in -2...2 {
                for dx in -2...2 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let d = (Float(dx * dx + dy * dy)).squareRoot()
                    k = max(k, nameAlpha[yy * w + xx] * max(0, min(1, halo + 0.5 - d)))
                }
            }
            if k > 0 { for c in 0..<4 { px[(y * w + x) * 4 + c] *= 1 - k } }
        }
    }
    let base = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(px.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let final = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    final.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
    final.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    final.setShouldSmoothFonts(false)
    for (line, origin) in nameDraws { final.textPosition = origin; CTLineDraw(line, final) }
    return final.makeImage()!
}

/// The app's BearOutline algorithm (0.62 outside / 0.20 inside, 1px disc), over the full row height.
func strongOutline(_ input: [Float], w: Int, h: Int, services: [String]) -> [Float] {
    let tones: [String: SIMD3<Float>] = ["codex": SIMD3(0.36, 0.25, 0.04), "claude": SIMD3(0.20, 0.14, 0.40),
                                        "antigravity": SIMD3(0.09, 0.27, 0.38), "stale": SIMD3(0.24, 0.24, 0.27)]
    var mask = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { mask[i] = max(0, min(1, (input[i * 4 + 3] - 0.06) / 0.4)) }
    func m(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= h) ? 0 : mask[y * w + x] }
    var runs: [(Int, Int)] = []
    for x in 0..<w where (0..<h).contains(where: { mask[$0 * w + x] > 0 }) {
        if let last = runs.last, x <= last.1 + 1 { runs[runs.count - 1].1 = x } else { runs.append((x, x)) }
    }
    func owner(_ x: Int) -> Int {
        runs.indices.min { a, b in
            func d(_ r: (Int, Int)) -> Int { x < r.0 ? r.0 - x : (x > r.1 ? x - r.1 : 0) }
            return d(runs[a]) < d(runs[b])
        } ?? 0
    }
    let kernel: [(Int, Int, Float)] = [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1),
                                       (-1, -1, 0.75), (1, -1, 0.75), (-1, 1, 0.75), (1, 1, 0.75)]
    var out = input
    for y in 0..<h {
        for x in 0..<w {
            let here = m(x, y)
            var grown = here, shrunk = here
            for (dx, dy, weight) in kernel {
                let v = m(x + dx, y + dy)
                grown = max(grown, v * weight); shrunk = min(shrunk, 1 - (1 - v) * weight)
            }
            let i = (y * w + x) * 4
            let ring = max(0, grown - here) * 0.62
            if ring > 0 {
                let tone = tones[services[min(owner(x), services.count - 1)]] ?? SIMD3(0.2, 0.2, 0.2)
                let behind = 1 - input[i + 3]
                for k in 0..<3 { out[i + k] += tone[k] * ring * behind }
                out[i + 3] += ring * behind
            }
            let edge = max(0, here - shrunk) * 0.20
            if edge > 0 { let a = out[i + 3]; for k in 0..<3 { out[i + k] += (a - out[i + k]) * edge } }
        }
    }
    return out
}

// MARK: - Sheets

let rowsToShow: [[MenuBarBearItem]] = [
    [MenuBarBearItem(percent: 54, name: "Codex", service: "codex"),
     MenuBarBearItem(percent: 89, name: "Claude", service: "claude"),
     MenuBarBearItem(percent: 100, name: "AGY", service: "antigravity")],
    [MenuBarBearItem(percent: 0, name: "Codex", service: "codex"),
     MenuBarBearItem(percent: 9, name: "Claude", service: "claude"),
     MenuBarBearItem(percent: 61, name: "AGY", service: "stale")]
]

enum Bar: CaseIterable {
    case light, dark, sky
    var color: Color { self == .light ? Color(white: 0.93) : self == .dark ? Color(white: 0.13) : Color(red: 0.80, green: 0.91, blue: 0.98) }
    var dark: Bool { self == .dark }
    var label: String { self == .light ? "라이트" : self == .dark ? "다크" : "밝은 하늘색" }
}

@MainActor
func image(_ option: String, _ items: [MenuBarBearItem], _ bar: Bar) -> NSImage {
    if option == "A" { return MenuBarBearImage.make(items, dark: bar.dark)! }
    return NSImage(cgImage: bRow(items, dark: bar.dark), size: rowSize)
}

struct Sheet: View {
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach(["A", "B"], id: \.self) { option in
                HStack(alignment: .center, spacing: 10 * u) {
                    Text(option == "A" ? "A 현재" : "B 개선").font(.system(size: 10 * u, weight: .bold)).frame(width: 44 * u, alignment: .leading)
                    VStack(spacing: 4 * u) {
                        ForEach(Bar.allCases, id: \.self) { bar in
                            HStack(spacing: 14 * zoom) {
                                ForEach(rowsToShow.indices, id: \.self) { i in
                                    let img = image(option, rowsToShow[i], bar)
                                    Image(nsImage: img).interpolation(.none).resizable()
                                        .frame(width: img.size.width * zoom, height: img.size.height * zoom)
                                }
                                Text("12:34").font(.system(size: 13 * zoom)).foregroundStyle(bar.dark ? Color.white : .black)
                            }
                            .padding(.horizontal, 10 * zoom).frame(height: 24 * zoom).background(bar.color)
                        }
                    }
                }
            }
            Text("각 줄: Codex 54 · Claude 89 · AGY 100  |  Codex 0 · Claude 9 · AGY 이전 데이터(회색 61)  — 두 안 모두 89×22pt")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black).padding(12 * u).background(Color.white)
    }
}

/// One bear of each option on the bright sky background, Retina pixels ×8, to compare ears and the name.
struct DetailSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("귀·이름 확대 — 밝은 하늘색, Retina 2배율 픽셀 보간 없이 8배 (왼쪽 A, 오른쪽 B)").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 24) {
                ForEach(["A", "B"], id: \.self) { option in
                    let img = image(option, [MenuBarBearItem(percent: 54, name: "Codex", service: "codex")], .sky)
                    let crop = option == "A" ? 23.0 : 23.0
                    Image(nsImage: img).interpolation(.none).resizable()
                        .frame(width: img.size.width * 8, height: img.size.height * 8)
                        .frame(width: crop * 8, alignment: .leading).clipped()
                        .background(Bar.sky.color)
                }
            }
        }
        .padding(16).background(Color.white).foregroundStyle(.black)
    }
}

@MainActor
func save<V: View>(_ view: V, scale: CGFloat, to name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
    try! NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", name, renderer.cgImage!.width, "x", renderer.cgImage!.height, "px")
}

// MARK: - Measurements

@MainActor
func report() {
    let L = layout()
    let a = BearAssets.set(service: "codex", scale: 2)!, b = BLayers.set("codex")
    func silhouette(_ img: CGImage) -> (w: CGFloat, h: CGFloat) {
        let px = rgba(img); var minX = img.width, maxX = -1, minY = img.height, maxY = -1
        for y in 0..<img.height { for x in 0..<img.width where px[(y * img.width + x) * 4 + 3] > 127 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        return (CGFloat(maxX - minX + 1) / 2, CGFloat(maxY - minY + 1) / 2)
    }
    let sa = silhouette(a.empty), sb = silhouette(b.empty)
    print(String(format: "bear silhouette A %.1f×%.1fpt → B %.1f×%.1fpt (×%.3f wide, ×%.3f high)", sa.w, sa.h, sb.w, sb.h, sb.w / sa.w, sb.h / sa.h))
    for text in ["0", "54", "89", "100"] {
        let fa = BearNumber.font(for: text), fb = roundedFont(text.count >= 3 ? bWideDigitSize : bDigitSize)
        let ia = CTLineGetBoundsWithOptions(ctLine(text, fa, .black), .useGlyphPathBounds)
        let ib = CTLineGetBoundsWithOptions(ctLine(text, fb, .black), .useGlyphPathBounds)
        print(String(format: "digits %-3@ A %.1fpt font, ink %.2f×%.2fpt → B %.1fpt font, ink %.2f×%.2fpt (×%.3f)",
                     text as NSString, CTFontGetSize(fa), ia.width, ia.height, CTFontGetSize(fb), ib.width, ib.height, ib.height / ia.height))
    }
    // Ears in outline units: radius 0.11 × 0.085 → ×1.05; in points they also grow with the bear.
    let aPt = 18 / 1.04, bPt = bWidth / 1.04
    print(String(format: "ear width: A %.2fpt, B %.2fpt (×%.3f absolute; ×1.050 relative to the face)",
                 0.22 * aPt, 0.22 * earScale * bPt, 0.22 * earScale * bPt / (0.22 * aPt)))
    print(String(format: "layout B: frame top %.2fpt, ear top %.2fpt, chin %.2fpt, number centre %.2fpt", L.frameTop, L.earTopY, L.chinY, L.numberCenterY))
    // Clipping / overlap checks on the composed B rows.
    for bar in Bar.allCases {
        for items in rowsToShow {
            let px = rgba(bRow(items, dark: bar.dark))
            let w = 178, h = 44
            let top = (0..<w).map { px[$0 * 4 + 3] }.max()!, bottom = (0..<w).map { px[((h - 1) * w + $0) * 4 + 3] }.max()!
            let left = (0..<h).map { px[($0 * w) * 4 + 3] }.max()!, right = (0..<h).map { px[($0 * w + w - 1) * 4 + 3] }.max()!
            print("B \(bar.label) \(items.map { BearNumber.text($0.percent) }.joined(separator: "/")): edge alpha top \(top) bottom \(bottom) left \(left) right \(right)")
        }
    }
}

@main
struct BMain {
    @MainActor static func main() {
        report()
        save(Sheet(zoom: 1, caption: "A 현재 vs B 이름-윤곽 통합 — Retina 2배율 실제 픽셀"), scale: 2, to: "50-bear-name-outline-actual-2x.png")
        save(Sheet(zoom: 4, caption: "확대 — Retina 2배율 픽셀 보간 없이 2배 (= 4배)"), scale: 1, to: "51-bear-name-outline-zoom4x.png")
        save(DetailSheet(), scale: 1, to: "52-bear-name-outline-detail.png")
    }
}
