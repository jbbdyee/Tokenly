// Exports the bear gauge assets (empty/full × service × 1x/2x/3x + manifest) and renders the
// comparison sheets. Every sheet loads the exported PNGs back through BearGaugeCompositor.
import AppKit
import CoreImage
import SwiftUI

let outputFolder = URL(fileURLWithPath: CommandLine.arguments[1])
let assetFolder = outputFolder.appendingPathComponent("assets")
let bearPoints = CGSize(width: 18, height: 16)
let nameBottomTrim: CGFloat = 1.75   // 16pt bear + 6.25pt name box − 0.25pt overlap = 22pt

extension BearColor {
    /// White digits only where the saturated fill is dark enough: at 18pt, white on champagne
    /// yellow or ice blue was too faint (checked on the Retina-pixel sheet), so those keep dark ink.
    var whiteTextWhenCovered: Bool { self == .claude }
    var serviceName: String { self == .antigravity ? "AGY" : self == .codex ? "Codex" : self == .claude ? "Claude" : "—" }
}

// MARK: - Export

@MainActor
enum Export {
    static let renderer = BearRenderer()
    static let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Supersampled ×8 in 3D, then Lanczos-reduced to the exact pixel grid.
    static func layer(_ color: BearColor, filled: Bool, pixelWidth: Int) -> CGImage {
        let source = renderer.render(color: color, filled: filled, pixelWidth: pixelWidth * 8)
        let scale = CGFloat(pixelWidth) / CGFloat(source.width)
        let height = Int((CGFloat(source.height) * scale).rounded())
        let output = CIImage(cgImage: source).applyingFilter("CILanczosScaleTransform",
                                                              parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        return ci.createCGImage(output, from: CGRect(x: 0, y: 0, width: pixelWidth, height: height),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    static func silhouetteRows(_ image: CGImage) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var top = image.height, bottom = 0
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 127 {
                top = min(top, y); bottom = max(bottom, y + 1); break
            }
        }
        return [top, bottom]
    }

    static func write(_ image: CGImage, _ name: String) {
        try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: assetFolder.appendingPathComponent(name))
    }

    static func run() {
        try? FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
        var fillRows: [String: [Int]] = [:]
        for scale in [1, 2, 3] {
            for color in BearColor.allCases {
                for filled in [false, true] {
                    let image = layer(color, filled: filled, pixelWidth: Int(bearPoints.width) * scale)
                    write(image, "bear-\(color.rawValue)-\(filled ? "full" : "empty")@\(scale)x.png")
                    if color == .codex && !filled { fillRows["\(scale)"] = silhouetteRows(image) }
                }
            }
        }
        // Face centre (0.49 of the 0.88-high unit frame) relative to the 16pt frame (0.9244 units high).
        let unitsHigh = 1.04 * 16.0 / 18.0
        let centerY = 8.0 + (0.49 - 0.44) / unitsHigh * 16.0
        let rows = fillRows["2"]!
        let topPt = Double(rows[0]) / 2, bottomPt = Double(rows[1]) / 2
        let numberTop = centerY - 2.8
        let covered = (bottomPt - numberTop) / (bottomPt - topPt)
        let manifest = BearManifest(pointSize: [18, 16], fillRows: fillRows, numberCenter: [9, centerY],
                                    numberCoveredAt: (covered * 100).rounded() / 100,
                                    services: BearColor.allCases.map(\.rawValue), layers: ["empty", "full"], scales: [1, 2, 3])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! encoder.encode(manifest).write(to: assetFolder.appendingPathComponent("bear-assets.json"))
        print("assets:", fillRows, "numberCenterY", String(format: "%.2f", centerY), "numberCoveredAt", manifest.numberCoveredAt)
    }
}

// MARK: - Text

struct Palette {
    let ink: Color, deep: Color, nameOnLight: Color, nameOnDark: Color
    static func of(_ color: BearColor) -> Palette {
        func c(_ v: UInt32) -> Color { Color(nsColor: hex(v)) }
        switch color {
        case .codex: return Palette(ink: c(0x7A5208), deep: c(0xA8740C), nameOnLight: c(0xB98612), nameOnDark: c(0xF6CF6A))
        case .claude: return Palette(ink: c(0x3E2C7C), deep: c(0x5A3FB8), nameOnLight: c(0x6E52D0), nameOnDark: c(0xC3B1FF))
        case .antigravity: return Palette(ink: c(0x154A66), deep: c(0x2275A3), nameOnLight: c(0x2A86C0), nameOnDark: c(0x9ED9F5))
        case .stale: return Palette(ink: c(0x45454B), deep: c(0x5E5F66), nameOnLight: c(0x6A6B72), nameOnDark: c(0xC9CAD0))
        }
    }
}

struct Outlined: View {
    let text: Text, fill: Color, outline: Color, width: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * .pi / 4
                text.foregroundStyle(outline).offset(x: CGFloat(cos(angle)) * width, y: CGFloat(sin(angle)) * width)
            }
            text.foregroundStyle(fill)
        }
    }
}

/// Dark ink with a white hairline over pale jelly; white with a deep-tone hairline once the
/// saturated fill covers the number (like the reference's 75%/100%).
struct NumberLabel: View {
    let text: String
    let color: BearColor
    let covered: Bool
    var scale: CGFloat = 1
    var body: some View {
        let p = Palette.of(color)
        let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
        let wide = digits.count >= 3
        var label = Text(digits).font(.system(size: (wide ? 6.1 : 7.3) * scale, weight: .black, design: .rounded))
        if text.hasSuffix("%") {
            label = label + Text("%").font(.system(size: (wide ? 4.3 : 4.8) * scale, weight: .heavy, design: .rounded))
        }
        return Outlined(text: label.tracking(-0.25 * scale).monospacedDigit(),
                        fill: covered ? .white : p.ink,
                        outline: covered ? p.deep.opacity(0.9) : .white.opacity(0.85),
                        width: 0.35 * scale)
            .fixedSize()
    }
}

// MARK: - Bear views built from the exported assets

struct Sample {
    let text: String
    let fraction: Double?
    let color: BearColor
    var label: String? = nil
}

@MainActor
enum Assets {
    static var manifest: BearManifest = {
        let data = try! Data(contentsOf: assetFolder.appendingPathComponent("bear-assets.json"))
        return try! JSONDecoder().decode(BearManifest.self, from: data)
    }()
    static func set(_ color: BearColor, scale: Int) -> BearAssetSet {
        BearGaugeCompositor.load(service: color.rawValue, scale: scale, from: assetFolder)!
    }
}

struct MenuBear: View {
    let sample: Sample
    let dark: Bool
    let pixelScale: Int
    var body: some View {
        let image = BearGaugeCompositor.image(Assets.set(sample.color, scale: pixelScale), fraction: sample.fraction)
        let covered = sample.color.whiteTextWhenCovered && (sample.fraction ?? 0) >= Assets.manifest.numberCoveredAt
        let p = Palette.of(sample.color)
        VStack(spacing: -0.25) {
            Image(decorative: image, scale: CGFloat(pixelScale)).interpolation(.none)
                .frame(width: bearPoints.width, height: bearPoints.height)
                .overlay {
                    NumberLabel(text: sample.text, color: sample.color, covered: covered)
                        .offset(y: Assets.manifest.numberCenter[1] - bearPoints.height / 2)
                }
            Text(sample.label ?? sample.color.serviceName)
                .font(.system(size: 6, weight: .heavy, design: .rounded))
                .foregroundStyle(dark ? p.nameOnDark : p.nameOnLight)
                .lineLimit(1).fixedSize()
                .padding(.bottom, -nameBottomTrim)
        }
    }
}

@MainActor
func rowImage(_ samples: [Sample], dark: Bool, pixelScale: Int) -> NSImage {
    let row = HStack(alignment: .top, spacing: 8) {
        ForEach(samples.indices, id: \.self) { MenuBear(sample: samples[$0], dark: dark, pixelScale: pixelScale) }
    }
    .padding(.horizontal, 1)
    .environment(\.colorScheme, dark ? .dark : .light)
    let natural = ImageRenderer(content: row)
    natural.scale = CGFloat(pixelScale)
    let width = natural.nsImage!.size.width.rounded(.up)
    // Whole-point bitmap, 22pt high, so the status item never resamples it.
    let snapped = ImageRenderer(content: row.frame(width: width, height: 22))
    snapped.scale = CGFloat(pixelScale)
    return snapped.nsImage!
}

let servicesRow = [Sample(text: "30%", fraction: 0.30, color: .codex),
                   Sample(text: "89%", fraction: 0.89, color: .claude),
                   Sample(text: "100%", fraction: 1.0, color: .antigravity)]
let stepsRow = [Sample(text: "0%", fraction: 0, color: .codex), Sample(text: "25%", fraction: 0.25, color: .codex),
                Sample(text: "50%", fraction: 0.5, color: .codex), Sample(text: "75%", fraction: 0.75, color: .codex),
                Sample(text: "100%", fraction: 1, color: .codex),
                Sample(text: "61%", fraction: 0.61, color: .stale, label: "Codex"),
                Sample(text: "?", fraction: nil, color: .stale, label: "Codex")]

let lightBar = Color(white: 0.93)
let darkBar = Color(white: 0.13)

struct Strip: View {
    let samples: [[Sample]]
    let dark: Bool
    let pixelScale: Int
    let zoom: CGFloat
    var body: some View {
        HStack(spacing: 14 * zoom) {
            ForEach(samples.indices, id: \.self) { i in
                let image = rowImage(samples[i], dark: dark, pixelScale: pixelScale)
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: image.size.width * zoom, height: image.size.height * zoom)
            }
            Text("12:34").font(.system(size: 13 * zoom)).foregroundStyle(dark ? Color.white : .black)
        }
        .padding(.horizontal, 10 * zoom)
        .frame(height: 24 * zoom)
        .background(dark ? darkBar : lightBar)
    }
}

struct MenuSheet: View {
    let pixelScale: Int
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach([[servicesRow], [stepsRow]].indices, id: \.self) { i in
                let rows = [[servicesRow], [stepsRow]][i]
                Strip(samples: rows, dark: false, pixelScale: pixelScale, zoom: zoom)
                Strip(samples: rows, dark: true, pixelScale: pixelScale, zoom: zoom)
            }
            Text("곰돌이 18×16pt · 간격 8pt · 이미지 높이 22pt · 아래 줄: 0/25/50/75/100% · 이전 데이터(회색 61%) · 데이터 없음(?)")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black)
        .padding(12 * u)
        .background(Color.white)
    }
}

// MARK: - Large views (same compositor on large, in-memory layers)

@MainActor
enum Large {
    static var cache: [String: BearAssetSet] = [:]
    static func set(_ color: BearColor, pixelWidth: Int) -> BearAssetSet {
        let key = "\(color)-\(pixelWidth)"
        if let hit = cache[key] { return hit }
        let empty = Export.renderer.render(color: color, filled: false, pixelWidth: pixelWidth)
        let full = Export.renderer.render(color: color, filled: true, pixelWidth: pixelWidth)
        let rows = Export.silhouetteRows(empty)
        let set = BearAssetSet(empty: empty, full: full, fillTop: rows[0], fillBottom: rows[1])
        cache[key] = set
        return set
    }
}

struct BigBear: View {
    let sample: Sample
    let width: CGFloat
    var dark = false
    var body: some View {
        let image = BearGaugeCompositor.image(Large.set(sample.color, pixelWidth: Int(width * 2)), fraction: sample.fraction)
        let scale = width / 18
        let covered = sample.color.whiteTextWhenCovered && (sample.fraction ?? 0) >= Assets.manifest.numberCoveredAt
        VStack(spacing: 6) {
            Image(decorative: image, scale: 2).frame(width: width, height: width * 16 / 18)
                .overlay {
                    NumberLabel(text: sample.text, color: sample.color, covered: covered, scale: scale)
                        .offset(y: (Assets.manifest.numberCenter[1] - 8) * scale)
                }
            Text(sample.label ?? sample.color.serviceName).font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(dark ? Palette.of(sample.color).nameOnDark : Palette.of(sample.color).nameOnLight)
        }
    }
}

struct OriginalSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("작은 귀 글래스 젤리 곰돌이 — 원본 렌더 (SceneKit PBR · 팽창 메시 · 유리 껍질 + 젤리 코어)")
                .font(.system(size: 18, weight: .bold))
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 30) {
                    ForEach(servicesRow.indices, id: \.self) { BigBear(sample: servicesRow[$0], width: 170, dark: dark) }
                    Rectangle().fill(.gray.opacity(0.3)).frame(width: 1, height: 150)
                    ForEach([BearColor.codex, .claude, .antigravity], id: \.self) { color in
                        BigBear(sample: Sample(text: "100%", fraction: 1, color: color), width: 120, dark: dark)
                    }
                }
                .padding(20)
                .background(dark ? darkBar : Color(white: 0.96))
            }
        }
        .padding(24)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

struct StepsSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("사용량 단계 — 원본 크기 (빈/채움 레이어를 잔여율로 마스킹)").font(.system(size: 18, weight: .bold))
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 18) {
                    ForEach(stepsRow.indices, id: \.self) { i in
                        let s = stepsRow[i]
                        VStack(spacing: 4) {
                            Text(i == 5 ? "61% (오래된 데이터)" : i == 6 ? "데이터 없음" : s.text)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(dark ? Color.white : .black)
                            BigBear(sample: s, width: 120, dark: dark)
                        }
                    }
                }
                .padding(18)
                .background(dark ? darkBar : Color(white: 0.96))
            }
        }
        .padding(24)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

@MainActor
func save<V: View>(_ view: V, scale: CGFloat, to name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    try! NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
        .write(to: outputFolder.appendingPathComponent(name))
    print("wrote", name, renderer.cgImage!.width, "x", renderer.cgImage!.height, "px")
}

@main
struct BearMain {
    @MainActor static func main() {
        let start = Date()
        Export.run()
        save(OriginalSheet(), scale: 1, to: "10-bear-original.png")
        save(StepsSheet(), scale: 1, to: "11-bear-gauge-steps.png")
        save(MenuSheet(pixelScale: 2, zoom: 1, caption: "메뉴 막대 실제 크기 — Retina 2배율 실제 픽셀 (내보낸 @2x 에셋 + 런타임 합성)"),
             scale: 2, to: "12-bear-menubar-2x-retina.png")
        save(MenuSheet(pixelScale: 2, zoom: 5, caption: "확대 — Retina 2배율 픽셀을 보간 없이 2.5배 (= 5배)"),
             scale: 1, to: "13-bear-menubar-zoom5x.png")
        save(MenuSheet(pixelScale: 1, zoom: 1, caption: "참고 — 1배율(비 Retina) 실제 픽셀 (@1x 에셋)"), scale: 1, to: "14-bear-menubar-1x.png")
        for (label, row) in [("services", servicesRow), ("steps", stepsRow)] {
            let image = rowImage(row, dark: false, pixelScale: 2)
            print("\(label) row: \(image.size.width)x\(image.size.height)pt")
        }
        print("total", String(format: "%.1fs", Date().timeIntervalSince(start)))
    }
}
