// Builds every comparison sheet for the 3D heart study.
// Gauge = two renders of the same lit 3D model (empty / full) blended per pixel row at the live level,
// so the volume and lighting stay intact at any percentage; numbers and names are separate SwiftUI layers.
import AppKit
import CoreImage
import SwiftUI

// MARK: - Layer cache and gauge compositing

@MainActor
final class Layers {
    static let shared = Layers()
    let renderer = HeartRenderer()
    private var cache: [String: CGImage] = [:]
    private let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// A layer at `pixelWidth`. Small sizes are supersampled ×8 in 3D, then Lanczos-reduced, so the
    /// silhouette and shading stay clean instead of relying on 4× MSAA at 36 px.
    func layer(_ style: HeartStyle, _ color: HeartColor, filled: Bool, pixelWidth: Int) -> CGImage {
        let key = "\(style)-\(color)-\(filled)-\(pixelWidth)"
        if let hit = cache[key] { return hit }
        let image: CGImage
        if pixelWidth >= 200 {
            image = renderer.render(style: style, color: color, filled: filled, pixelWidth: pixelWidth)
        } else {
            let source = layer(style, color, filled: filled, pixelWidth: pixelWidth * 8)
            image = downscale(source, toWidth: pixelWidth)
        }
        cache[key] = image
        return image
    }

    private func downscale(_ image: CGImage, toWidth width: Int) -> CGImage {
        let scale = CGFloat(width) / CGFloat(image.width)
        let height = Int((CGFloat(image.height) * scale).rounded())
        let output = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform",
                                                             parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        return ci.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
}

struct Pixels {
    let width: Int, height: Int
    var data: [Float]   // premultiplied RGBA, 0...1, top row first

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = bytes.map { Float($0) / 255 }
    }

    func image() -> CGImage {
        let bytes = data.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    func alpha(_ x: Int, _ y: Int) -> Float { data[(y * width + x) * 4 + 3] }
}

enum Gauge {
    /// Heart at `fraction` (nil = no data → empty). Blend coverage is fractional per row, so even a
    /// 32-px-high heart moves smoothly between percentages; a thin light line marks the liquid surface.
    @MainActor
    static func heart(_ style: HeartStyle, _ color: HeartColor, fraction: Double?, pixelWidth: Int) -> CGImage {
        let empty = Pixels(Layers.shared.layer(style, color, filled: false, pixelWidth: pixelWidth))
        let full = Pixels(Layers.shared.layer(style, color, filled: true, pixelWidth: pixelWidth))
        let f = Float(min(max(fraction ?? 0, 0), 1))
        // Silhouette extent from the shell's alpha, so 0–100% maps onto the heart, not the padded frame.
        var top = empty.height, bottom = 0
        for y in 0..<empty.height {
            for x in 0..<empty.width where empty.alpha(x, y) > 0.5 { top = min(top, y); bottom = max(bottom, y + 1); break }
        }
        let level = Float(bottom) - f * Float(bottom - top)       // y of the surface, in pixels from the top
        let lineWidth = max(0.6, Float(pixelWidth) * 0.012)
        let lineStrength: Float = style == .glass ? 0.5 : 0.28
        var out = empty
        for y in 0..<out.height {
            // Fraction of this pixel row that lies below the surface.
            let coverage = max(0, min(1, Float(y + 1) - level))
            let distance = abs(Float(y) + 0.5 - level)
            let line = (f > 0.02 && f < 0.98) ? max(0, 1 - distance / lineWidth) * lineStrength : 0
            for x in 0..<out.width {
                let i = (y * out.width + x) * 4
                for c in 0..<4 { out.data[i + c] = empty.data[i + c] * (1 - coverage) + full.data[i + c] * coverage }
                if line > 0 {
                    let a = out.data[i + 3]
                    for c in 0..<3 { out.data[i + c] += (a - out.data[i + c]) * line }
                }
            }
        }
        return out.image()
    }
}

// MARK: - Text layers (legibility study C numbers / B names), drawn above the 3D image

struct Ink {
    let number: Color, nameOnLight: Color, nameOnDark: Color
    static func of(_ color: HeartColor) -> Ink {
        func c(_ v: UInt32) -> Color { Color(nsColor: hex(v)) }
        switch color {
        case .codex: return Ink(number: c(0x6A4508), nameOnLight: c(0xA77812), nameOnDark: c(0xF6D27A))
        case .claude: return Ink(number: c(0x3B2A75), nameOnLight: c(0x6247C2), nameOnDark: c(0xCBBBFF))
        case .antigravity: return Ink(number: c(0x15465F), nameOnLight: c(0x2A7BA5), nameOnDark: c(0xB4E3F7))
        case .stale: return Ink(number: c(0x45454B), nameOnLight: c(0x5E5E66), nameOnDark: c(0xD4D4D9))
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

struct NumberLabel: View {
    let text: String
    let ink: Color
    var scale: CGFloat = 1
    var body: some View {
        let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
        let wide = digits.count >= 3
        var label = Text(digits).font(.system(size: (wide ? 6.1 : 7.3) * scale, weight: .black, design: .rounded))
        if text.hasSuffix("%") {
            label = label + Text("%").font(.system(size: (wide ? 4.3 : 4.8) * scale, weight: .heavy, design: .rounded))
        }
        return Outlined(text: label.tracking(-0.25 * scale).monospacedDigit(), fill: ink,
                        outline: .white.opacity(0.85), width: 0.35 * scale)
            .fixedSize()
    }
}

// MARK: - Menu bar layout (18 × 16pt heart, 8pt spacing, name 0.25pt overlap, 22pt high)

struct Sample {
    let text: String
    let fraction: Double?
    let name: String
    let color: HeartColor
}

let rowFresh = [Sample(text: "30%", fraction: 0.30, name: "Codex", color: .codex),
                Sample(text: "89%", fraction: 0.89, name: "Claude", color: .claude),
                Sample(text: "100%", fraction: 1.0, name: "AGY", color: .antigravity)]
let rowEdge = [Sample(text: "0%", fraction: 0, name: "Codex", color: .codex),
               Sample(text: "61%", fraction: 0.61, name: "Claude", color: .stale),   // stale: last value, grey
               Sample(text: "?", fraction: nil, name: "AGY", color: .stale)]          // no data (app hides it today)

let heartPoints = CGSize(width: 18, height: 16)
let nameBottomTrim: CGFloat = 1.75   // 16pt heart frame + 6.25pt name box − 0.25pt overlap = 22pt

struct MenuHeart: View {
    let style: HeartStyle
    let sample: Sample
    let dark: Bool
    let pixelScale: Int
    var body: some View {
        let image = Gauge.heart(style, sample.color, fraction: sample.fraction, pixelWidth: Int(heartPoints.width) * pixelScale)
        let ink = Ink.of(sample.color)
        VStack(spacing: MenuBarHeart.nameSpacing) {
            Image(decorative: image, scale: CGFloat(pixelScale)).interpolation(.none)
                .frame(width: heartPoints.width, height: heartPoints.height)
                .overlay { NumberLabel(text: sample.text, ink: ink.number).offset(y: 0.3) }
            Text(sample.name).font(.system(size: MenuBarHeart.nameFontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(dark ? ink.nameOnDark : ink.nameOnLight)
                .lineLimit(1).fixedSize()
                .padding(.bottom, -nameBottomTrim)
        }
    }
}

/// The app's current heart row, untouched, as the reference.
struct CurrentRow: View {
    let samples: [Sample]
    var body: some View {
        HStack(alignment: .top, spacing: MenuBarHeartRow.heartSpacing) {
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                let palette: HeartPalette = s.color == .stale ? .stale : s.color == .codex ? .codex
                    : s.color == .claude ? .claude : .antigravity
                if let f = s.fraction {
                    MenuBarHeart(percent: f * 100, name: s.name, palette: palette)
                } else {
                    VStack(spacing: MenuBarHeart.nameSpacing) {
                        JellyHeart(fraction: nil, palette: palette, width: MenuBarHeart.width) {
                            Text("?").font(.system(size: MenuBarHeart.percentFontSize, weight: .heavy, design: .rounded))
                                .foregroundStyle(palette.ink).fixedSize()
                        }
                        Text(s.name).font(.system(size: MenuBarHeart.nameFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.rim).fixedSize().padding(.bottom, -MenuBarHeart.nameBottomTrim)
                    }
                }
            }
        }
        .padding(.horizontal, 1)
    }
}

enum RowKind: String, CaseIterable { case current = "현재 앱", soft = "소프트 3D", glass = "글래스 젤리 3D" }

@MainActor
func rowImage(_ kind: RowKind, _ samples: [Sample], dark: Bool, pixelScale: Int) -> NSImage {
    let content: AnyView
    switch kind {
    case .current: content = AnyView(CurrentRow(samples: samples))
    case .soft, .glass:
        let style: HeartStyle = kind == .soft ? .soft : .glass
        content = AnyView(HStack(alignment: .top, spacing: MenuBarHeartRow.heartSpacing) {
            ForEach(samples.indices, id: \.self) { MenuHeart(style: style, sample: samples[$0], dark: dark, pixelScale: pixelScale) }
        }
        .padding(.horizontal, 1))
    }
    let first = ImageRenderer(content: content.environment(\.colorScheme, dark ? .dark : .light))
    first.scale = CGFloat(pixelScale)
    let size = first.nsImage!.size
    guard kind != .current else { return first.nsImage! }
    // Whole-point bitmap (here 22pt high) so the status item never resamples it.
    let snapped = ImageRenderer(content: content.frame(width: size.width.rounded(.up), height: 22)
        .environment(\.colorScheme, dark ? .dark : .light))
    snapped.scale = CGFloat(pixelScale)
    return snapped.nsImage!
}

let lightBar = Color(white: 0.93)
let darkBar = Color(white: 0.13)

struct Strip: View {
    let kind: RowKind
    let dark: Bool
    let pixelScale: Int
    let zoom: CGFloat
    var body: some View {
        HStack(spacing: 14 * zoom) {
            ForEach([rowFresh, rowEdge].indices, id: \.self) { i in
                let image = rowImage(kind, [rowFresh, rowEdge][i], dark: dark, pixelScale: pixelScale)
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
        VStack(alignment: .leading, spacing: 10 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach(RowKind.allCases, id: \.self) { kind in
                HStack(spacing: 12 * u) {
                    Text(kind.rawValue).font(.system(size: 9 * u, weight: .bold)).frame(width: 70 * u, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Strip(kind: kind, dark: false, pixelScale: pixelScale, zoom: zoom)
                        Strip(kind: kind, dark: true, pixelScale: pixelScale, zoom: zoom)
                    }
                }
            }
            Text("왼쪽: 30% · 89% · 100%   오른쪽: 0% · 이전 데이터(회색 61%) · 데이터 없음(?)  — 하트 18×16pt, 간격 8pt, 높이 22pt")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black)
        .padding(12 * u)
        .background(Color.white)
    }
}

// MARK: - Large originals

struct BigHeart: View {
    let style: HeartStyle
    let color: HeartColor
    let fraction: Double?
    let width: CGFloat
    var label: String? = nil
    var body: some View {
        let image = Gauge.heart(style, color, fraction: fraction, pixelWidth: Int(width * 2))
        VStack(spacing: 4) {
            Image(decorative: image, scale: 2).frame(width: width, height: width * 16 / 18)
                .overlay { if let label { NumberLabel(text: label, ink: Ink.of(color).number, scale: width / 18) } }
        }
    }
}

struct OriginalSheet: View {
    let style: HeartStyle
    var body: some View {
        let colors: [HeartColor] = [.codex, .claude, .antigravity, .stale]
        VStack(alignment: .leading, spacing: 18) {
            Text(style == .soft ? "소프트 3D 하트 — 원본 (SceneKit PBR, 팽창 메시)" : "글래스 젤리 3D 하트 — 원본 (SceneKit PBR, 유리 껍질 + 젤리 코어)")
                .font(.system(size: 20, weight: .bold))
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 26) {
                    ForEach(colors, id: \.self) { color in
                        VStack(spacing: 8) {
                            BigHeart(style: style, color: color, fraction: color == .stale ? 0.61 : 1, width: 200)
                            Text(color == .stale ? "이전 데이터(회색)" : color == .codex ? "Codex #F4C75B" : color == .claude ? "Claude #A58CEB" : "AGY #86C9E8")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                }
                .padding(20)
                .background(dark ? darkBar : Color(white: 0.95))
                .foregroundStyle(dark ? Color.white : .black)
            }
        }
        .padding(24)
        .background(Color.white)
    }
}

struct ColorSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("두 스타일 × 세 서비스 색 (잔여 70%)").font(.system(size: 20, weight: .bold))
            ForEach([HeartStyle.soft, .glass], id: \.self) { style in
                HStack(spacing: 20) {
                    Text(style == .soft ? "소프트 3D" : "글래스 젤리").font(.system(size: 14, weight: .semibold)).frame(width: 90)
                    ForEach([HeartColor.codex, .claude, .antigravity], id: \.self) { color in
                        BigHeart(style: style, color: color, fraction: 0.7, width: 150, label: "70%")
                    }
                    Rectangle().fill(.clear).frame(width: 10)
                    ForEach([HeartColor.codex, .claude, .antigravity], id: \.self) { color in
                        BigHeart(style: style, color: color, fraction: 0.7, width: 150, label: "70%")
                            .padding(10).background(darkBar)
                    }
                }
            }
        }
        .padding(24)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

struct GaugeSheet: View {
    var body: some View {
        let steps: [Double] = [0, 0.25, 0.5, 0.75, 1]
        VStack(alignment: .leading, spacing: 16) {
            Text("채움 단계 0 · 25 · 50 · 75 · 100% — 위: 원본 크기, 아래: 실제 18pt (Retina 2배 픽셀, 보간 없이 5배 확대)")
                .font(.system(size: 18, weight: .bold))
            ForEach([HeartStyle.soft, .glass], id: \.self) { style in
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 16) {
                        Text("\(style == .soft ? "소프트" : "글래스") \(dark ? "다크" : "라이트")")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 90)
                        ForEach(steps, id: \.self) { f in
                            BigHeart(style: style, color: .claude, fraction: f, width: 110, label: "\(Int(f * 100))%")
                        }
                        Rectangle().fill(.gray.opacity(0.4)).frame(width: 1, height: 90)
                        ForEach(steps, id: \.self) { f in
                            let image = Gauge.heart(style, .codex, fraction: f, pixelWidth: 36)
                            Image(decorative: image, scale: 1).interpolation(.none).resizable()
                                .frame(width: 36 * 2.5, height: 32 * 2.5)
                        }
                    }
                    .padding(12)
                    .background(dark ? darkBar : Color(white: 0.95))
                    .foregroundStyle(dark ? Color.white : .black)
                }
            }
        }
        .padding(24)
        .background(Color.white)
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
struct Main {
    @MainActor static func main() {
        let start = Date()
        save(OriginalSheet(style: .soft), scale: 1, to: "01-soft3d-original.png")
        save(OriginalSheet(style: .glass), scale: 1, to: "02-glass3d-original.png")
        save(ColorSheet(), scale: 1, to: "03-colors.png")
        save(GaugeSheet(), scale: 1, to: "04-gauge-steps.png")
        save(MenuSheet(pixelScale: 2, zoom: 1, caption: "메뉴 막대 최종 배치 — Retina 2배율 실제 픽셀"), scale: 2, to: "05-menubar-2x-retina.png")
        save(MenuSheet(pixelScale: 2, zoom: 5, caption: "메뉴 막대 최종 배치 — Retina 2배율 픽셀을 보간 없이 2.5배 확대 (= 5배)"), scale: 1, to: "06-menubar-zoom5x.png")
        save(MenuSheet(pixelScale: 1, zoom: 1, caption: "참고: 1배율(비 Retina) 실제 픽셀"), scale: 1, to: "07-menubar-1x.png")
        for kind in RowKind.allCases {
            let image = rowImage(kind, rowFresh, dark: false, pixelScale: 2)
            print("\(kind.rawValue) row: \(image.size.width)x\(image.size.height)pt")
        }
        print("total", String(format: "%.1fs", Date().timeIntervalSince(start)))
    }
}
