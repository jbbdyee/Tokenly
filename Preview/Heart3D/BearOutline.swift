// Outline study for the menu bar bear: the app's own row image (MenuBarBearImage, unchanged) plus a
// silhouette-following double outline: a thin translucent dark ring just outside the bear's alpha and,
// for medium/strong, a faint light line just inside it next to the existing glass rim.
// Preview-only; compiled with the app's sources read-only. Run ./run-outline.sh.
import AppKit
import SwiftUI

struct OutlineStrength {
    let name: String
    /// Opacity of the dark ring outside the silhouette.
    let outer: Float
    /// Opacity of the light line just inside the silhouette (0 = keep the rendered glass rim only).
    let inner: Float
    static let none = OutlineStrength(name: "현재", outer: 0, inner: 0)
    static let weak = OutlineStrength(name: "약함", outer: 0.30, inner: 0)
    static let medium = OutlineStrength(name: "중간", outer: 0.45, inner: 0.12)
    static let strong = OutlineStrength(name: "강함", outer: 0.62, inner: 0.2)
    static let all = [none, weak, medium, strong]
}

/// Premultiplied RGBA bitmap, top row first.
struct Bitmap {
    let width: Int, height: Int
    var px: [Float]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        px = bytes.map { Float($0) / 255 }
    }

    func image() -> CGImage {
        let bytes = px.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}

/// Adds the outline to a rendered bear row. Only the bear band (top 16pt) is used, so the names below
/// are never outlined; the ring follows the alpha silhouette, never the bitmap rectangle.
func outlined(_ row: CGImage, scale: Int, strength: OutlineStrength, ringColor: (Int) -> SIMD3<Float>) -> CGImage {
    guard strength.outer > 0 || strength.inner > 0 else { return row }
    var bitmap = Bitmap(row)
    let w = bitmap.width, h = bitmap.height
    let band = min(h, 16 * scale + 1)   // one row below the bear frame for the ring under the chin
    // Soft silhouette mask: the glass edge fades in from very low alpha.
    var mask = [Float](repeating: 0, count: w * h)
    for y in 0..<band { for x in 0..<w { mask[y * w + x] = max(0, min(1, (bitmap.px[(y * w + x) * 4 + 3] - 0.06) / 0.4)) } }
    // Names start below the bear frame; keep them out of the mask.
    for y in (16 * scale)..<band { for x in 0..<w { mask[y * w + x] = 0 } }
    func m(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= band) ? 0 : mask[y * w + x] }
    // Owner bear per column from runs of occupied columns (the first version guessed from 26pt slots and
    // tinted Claude's right edge with AGY's hue).
    var runs: [(Int, Int)] = []
    for x in 0..<w where (0..<(16 * scale)).contains(where: { mask[$0 * w + x] > 0 }) {
        if let last = runs.last, x <= last.1 + 1 { runs[runs.count - 1].1 = x } else { runs.append((x, x)) }
    }
    func owner(_ x: Int) -> Int {
        runs.indices.min { a, b in
            func d(_ r: (Int, Int)) -> Int { x < r.0 ? r.0 - x : (x > r.1 ? x - r.1 : 0) }
            return d(runs[a]) < d(runs[b])
        } ?? 0
    }
    // ~1px disc dilation / erosion (diagonals weighted 0.75) at Retina; ~0.5pt.
    let neighbours: [(Int, Int, Float)] = [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1),
                                           (-1, -1, 0.75), (1, -1, 0.75), (-1, 1, 0.75), (1, 1, 0.75)]
    for y in 0..<band {
        for x in 0..<w {
            let here = m(x, y)
            var grown = here, shrunk = here
            for (dx, dy, weight) in neighbours {
                let v = m(x + dx, y + dy)
                grown = max(grown, v * weight)
                shrunk = min(shrunk, 1 - (1 - v) * weight)
            }
            let i = (y * w + x) * 4
            // Outer: dark ring painted behind the existing pixel (destination-over), so glass stays on top.
            let ring = max(0, grown - here) * strength.outer
            if ring > 0 {
                let c = ringColor(owner(x))
                let behind = 1 - bitmap.px[i + 3]
                for k in 0..<3 { bitmap.px[i + k] += c[k] * ring * behind }
                bitmap.px[i + 3] += ring * behind
            }
            // Inner: faint light line on the outermost opaque pixels, beside the rendered glass rim.
            let edge = max(0, here - shrunk) * strength.inner
            if edge > 0 {
                let a = bitmap.px[i + 3]
                for k in 0..<3 { bitmap.px[i + k] += (a - bitmap.px[i + k]) * edge }
            }
        }
    }
    return bitmap.image()
}

// MARK: - Samples (same as the app: three services and the edge states)

let services = [MenuBarBearItem(percent: 30, name: "Codex", service: "codex"),
                MenuBarBearItem(percent: 89, name: "Claude", service: "claude"),
                MenuBarBearItem(percent: 100, name: "AGY", service: "antigravity")]
let edges = [MenuBarBearItem(percent: 0, name: "Codex", service: "codex"),
             MenuBarBearItem(percent: 61, name: "Claude", service: "stale"),
             MenuBarBearItem(percent: 100, name: "AGY", service: "antigravity")]

/// Dark ring tinted with each bear's hue so it reads as the bear's own edge, not a black border.
func ringColors(_ items: [MenuBarBearItem]) -> (Int) -> SIMD3<Float> {
    let tones: [String: SIMD3<Float>] = ["codex": SIMD3(0.36, 0.25, 0.04), "claude": SIMD3(0.20, 0.14, 0.40),
                                        "antigravity": SIMD3(0.09, 0.27, 0.38), "stale": SIMD3(0.24, 0.24, 0.27)]
    return { index in tones[items[max(0, min(items.count - 1, index))].service] ?? SIMD3(0.2, 0.2, 0.2) }
}

enum Background: CaseIterable {
    case light, dark, sky
    var color: Color {
        switch self {
        case .light: Color(white: 0.93)
        case .dark: Color(white: 0.13)
        case .sky: Color(red: 0.80, green: 0.91, blue: 0.98)   // bright sky-blue wallpaper through the bar
        }
    }
    var isDark: Bool { self == .dark }
    var label: String { self == .light ? "라이트" : self == .dark ? "다크" : "밝은 하늘색" }
}

@MainActor
func row(_ items: [MenuBarBearItem], _ background: Background, _ strength: OutlineStrength, scale: Int) -> NSImage {
    // The app's raw row (MenuBarBearRow, names black/white by bar appearance) without the app's own
    // outline, which MenuBarBearImage now adds; then this study's outline post-process.
    let size = rawSize(items)
    let r = ImageRenderer(content: MenuBarBearRow(items: items, scale: scale, dark: background.isDark)
        .frame(width: size.width, height: 22))
    r.scale = CGFloat(scale)
    let result = outlined(r.cgImage!, scale: scale, strength: strength, ringColor: ringColors(items))
    return NSImage(cgImage: result, size: size)
}

@MainActor
func rawSize(_ items: [MenuBarBearItem]) -> CGSize {
    let natural = ImageRenderer(content: MenuBarBearRow(items: items, scale: 2, dark: false))
    natural.scale = 2
    return CGSize(width: natural.nsImage!.size.width.rounded(.up), height: 22)
}

struct Strip: View {
    let background: Background
    let strength: OutlineStrength
    let scale: Int
    let zoom: CGFloat
    var body: some View {
        HStack(spacing: 14 * zoom) {
            ForEach([services, edges].indices, id: \.self) { i in
                let image = row([services, edges][i], background, strength, scale: scale)
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: image.size.width * zoom, height: image.size.height * zoom)
            }
            Text("12:34").font(.system(size: 13 * zoom)).foregroundStyle(background.isDark ? Color.white : .black)
        }
        .padding(.horizontal, 10 * zoom)
        .frame(height: 24 * zoom)
        .background(background.color)
    }
}

struct Sheet: View {
    let scale: Int
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            HStack(alignment: .top, spacing: 14 * u) {
                Text("").frame(width: 40 * u)
                ForEach(Background.allCases, id: \.self) { bg in
                    Text(bg.label).font(.system(size: 9 * u, weight: .semibold)).frame(width: 214 * zoom, alignment: .leading)
                }
            }
            ForEach(OutlineStrength.all, id: \.name) { strength in
                HStack(spacing: 14 * u) {
                    Text(strength.name).font(.system(size: 10 * u, weight: .bold)).frame(width: 40 * u, alignment: .leading)
                    ForEach(Background.allCases, id: \.self) { bg in
                        Strip(background: bg, strength: strength, scale: scale, zoom: zoom)
                    }
                }
            }
            Text("왼쪽: Codex 30 · Claude 89 · AGY 100   오른쪽: 0% · 이전 데이터(회색 61) · 100%   — 곰돌이 18×16pt, 간격 8pt, 높이 22pt")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black)
        .padding(12 * u)
        .background(Color.white)
    }
}

/// Ear and crown close-up on the bright sky-blue background, Retina pixels ×10, no smoothing.
struct EarSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("귀·정수리 확대 — 밝은 하늘색 배경, Retina 2배율 픽셀을 보간 없이 10배").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 16) {
                ForEach(OutlineStrength.all, id: \.name) { strength in
                    VStack(spacing: 6) {
                        Text(strength.name).font(.system(size: 14, weight: .bold))
                        let image = row([services[1]], .sky, strength, scale: 2)
                        Image(nsImage: image).interpolation(.none).resizable()
                            .frame(width: image.size.width * 10, height: image.size.height * 10)
                            .background(Background.sky.color)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .foregroundStyle(.black)
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

@main
struct OutlineMain {
    @MainActor static func main() {
        save(Sheet(scale: 2, zoom: 1, caption: "실제 메뉴 막대 크기 18pt — Retina 2배율 실제 픽셀 (100% 보기 기준)"), scale: 2,
             to: "30-bear-outline-actual-2x.png")
        save(Sheet(scale: 2, zoom: 4, caption: "확대 — Retina 2배율 픽셀을 보간 없이 2배 (= 4배)"), scale: 1,
             to: "31-bear-outline-zoom4x.png")
        save(Sheet(scale: 1, zoom: 1, caption: "참고 — 1배율(비 Retina) 실제 픽셀"), scale: 1, to: "32-bear-outline-1x.png")
        save(EarSheet(), scale: 1, to: "33-bear-outline-ear-detail.png")
        for strength in OutlineStrength.all {
            let image = row(services, .sky, strength, scale: 2)
            print(strength.name, "row", image.size)
        }
        // The app adopted "강함": its MenuBarBearImage output must match this study pixel for pixel.
        for background in Background.allCases {
            for items in [services, edges] {
                let study = row(items, background, .strong, scale: 2)
                let app = MenuBarBearImage.make(items, dark: background.isDark)!
                func pixels(_ image: NSImage) -> [UInt8] {
                    var rect = CGRect(origin: .zero, size: image.size)
                    return Array(Bitmap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!).px.map { UInt8(($0 * 255).rounded()) })
                }
                let a = pixels(study), b = pixels(app)
                let diff = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? -1
                var spots: [String] = []
                for i in stride(from: 0, to: a.count, by: 4) where (0..<4).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 2 }) {
                    spots.append("(\((i / 4) % 162),\((i / 4) / 162))")
                }
                if !spots.isEmpty { print("   differing px:", spots.count, spots.prefix(12).joined(separator: " ")) }
                print("app vs study 강함 \(background.label) \(items.count) bears: size \(app.size), max channel diff \(diff)")
            }
        }
    }
}
