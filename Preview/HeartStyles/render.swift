// Style comparison for the menu bar hearts: A current, B soft 3D, C glass jelly.
// Preview-only: not part of the Xcode project. Reuses the app's HeartShape/JellyHeart/MenuBarHeart read-only.
// Run ./run.sh from this folder.
import AppKit
import SwiftUI

// MARK: - Palette shared by B and C (same hue families as the app: coral, lavender, ice blue, grey)

func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255)
}

struct Tone {
    let pale: Color, light: Color, base: Color, deep: Color, ink: Color
    let nameOnLight: Color, nameOnDark: Color

    static let codex = Tone(pale: rgb(0xFFE4DF), light: rgb(0xFFC3B9), base: rgb(0xFF8E83), deep: rgb(0xDC5A53),
                            ink: rgb(0x7E2525), nameOnLight: rgb(0xC2413D), nameOnDark: rgb(0xFFB3A7))
    static let claude = Tone(pale: rgb(0xEFE8FF), light: rgb(0xDCCEFF), base: rgb(0xB49AF0), deep: rgb(0x7C5CC9),
                             ink: rgb(0x3F2A72), nameOnLight: rgb(0x5E3FA8), nameOnDark: rgb(0xD7C6FF))
    static let antigravity = Tone(pale: rgb(0xE2F4FF), light: rgb(0xC4E8FF), base: rgb(0x86CBF2), deep: rgb(0x3E92C6),
                                  ink: rgb(0x174A6C), nameOnLight: rgb(0x1F6FA3), nameOnDark: rgb(0xB5E2FF))
    static let stale = Tone(pale: rgb(0xEDEDF0), light: rgb(0xDADADF), base: rgb(0xB3B3BA), deep: rgb(0x85858D),
                            ink: rgb(0x45454B), nameOnLight: rgb(0x5E5E66), nameOnDark: rgb(0xD4D4D9))
}

/// HeartShape drawn inside its rect, so strokes never spill past the image edge.
struct InsetHeart: Shape {
    var inset: CGFloat
    func path(in rect: CGRect) -> Path { HeartShape().path(in: rect.insetBy(dx: inset, dy: inset)) }
}

/// Bottom-up level fill clipped to the heart; `fraction` comes from the live remaining percent.
struct Level<Fill: View>: View {
    let fraction: Double
    let height: CGFloat
    @ViewBuilder var fill: () -> Fill
    var body: some View {
        fill()
            .frame(height: height * CGFloat(min(max(fraction, 0), 1)))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipShape(HeartShape())
    }
}

// MARK: - B: soft 3D (matte silicone / clay)

struct SoftHeart: View {
    let fraction: Double?
    let tone: Tone
    let width: CGFloat

    var body: some View {
        let height = width * JellyHeart<EmptyView>.aspect
        let level = fraction ?? 0
        ZStack {
            // Empty part: pale, low-saturation clay of the same hue.
            HeartShape().fill(Color.white)
            HeartShape().fill(LinearGradient(colors: [tone.pale.opacity(0.55), tone.pale], startPoint: .top, endPoint: .bottom))
            Level(fraction: level, height: height) {
                LinearGradient(colors: [tone.base, tone.deep.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            }
            if level > 0.02 && level < 0.98 {
                Level(fraction: level, height: height) {
                    VStack(spacing: 0) { Rectangle().fill(.white.opacity(0.35)).frame(height: 0.5); Spacer(minLength: 0) }
                }
            }
            // Volume: a soft inner shadow on the lower right, as if lit from the upper left.
            HeartShape().stroke(Color.black.opacity(0.12), lineWidth: 2.6)
                .blur(radius: 1.1).offset(x: -0.5, y: -0.7)
                .clipShape(HeartShape())
            // Broad, diffuse top light instead of a hard white spot.
            HeartShape().fill(RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                             center: UnitPoint(x: 0.3, y: 0.24), startRadius: 0, endRadius: width * 0.42))
            // Hairline edge keeps the silhouette on light menu bars without a thick outline.
            InsetHeart(inset: 0.25).stroke(tone.deep.opacity(0.3), lineWidth: 0.5)
        }
        .frame(width: width, height: height)
        .shadow(color: tone.deep.opacity(0.22), radius: 0.6, y: 0.4)
    }
}

// MARK: - C: glass jelly (tinted translucent glass with a jelly level)

struct GlassHeart: View {
    let fraction: Double?
    let tone: Tone
    let width: CGFloat

    var body: some View {
        let height = width * JellyHeart<EmptyView>.aspect
        let level = fraction ?? 0
        ZStack {
            // Tinted glass body; a faint frost keeps the centre light enough for dark digits on dark bars.
            HeartShape().fill(LinearGradient(colors: [tone.light.opacity(0.5), tone.base.opacity(0.32)],
                                             startPoint: .top, endPoint: .bottom))
            HeartShape().fill(Color.white.opacity(0.32))
            Level(fraction: level, height: height) {
                LinearGradient(colors: [tone.base.opacity(0.85), tone.deep.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            }
            if level > 0.02 && level < 0.98 {
                Level(fraction: level, height: height) {
                    VStack(spacing: 0) { Rectangle().fill(.white.opacity(0.6)).frame(height: 0.5); Spacer(minLength: 0) }
                }
            }
            // Light caught inside the glass edge.
            InsetHeart(inset: 0.6).stroke(.white.opacity(0.55), lineWidth: 0.8)
                .blur(radius: 0.35).clipShape(HeartShape())
            // Small caustic glow near the tip.
            Ellipse().fill(.white.opacity(0.3)).frame(width: width * 0.32, height: width * 0.12)
                .blur(radius: 0.7).offset(y: height * 0.24)
            // Thin reflection streak on the left lobe instead of a big white spot.
            Capsule().fill(.white.opacity(0.6)).frame(width: width * 0.2, height: width * 0.05)
                .rotationEffect(.degrees(-35)).blur(radius: 0.2)
                .offset(x: -width * 0.22, y: -height * 0.22)
            InsetHeart(inset: 0.3).stroke(tone.deep.opacity(0.55), lineWidth: 0.6)
            // Frost only behind the digits, so dark bars cannot bleed through the number.
            Ellipse().fill(.white.opacity(0.45)).frame(width: width * 0.7, height: height * 0.42)
                .blur(radius: 1.2).offset(y: -0.3)
        }
        .frame(width: width, height: height)
        .shadow(color: tone.deep.opacity(0.18), radius: 0.5, y: 0.3)
    }
}

// MARK: - Text layers (from the legibility study's C numbers / B names), kept outside the heart's shadow

struct Outlined: View {
    let text: Text
    let fill: Color
    let outline: Color
    let width: CGFloat
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
    var body: some View {
        let digits = text.hasSuffix("%") ? String(text.dropLast()) : text
        let wide = digits.count >= 3
        var label = Text(digits).font(.system(size: wide ? 6.1 : 7.3, weight: .black, design: .rounded))
        if text.hasSuffix("%") {
            label = label + Text("%").font(.system(size: wide ? 4.3 : 4.8, weight: .heavy, design: .rounded))
        }
        return Outlined(text: label.tracking(-0.25).monospacedDigit(), fill: ink, outline: .white.opacity(0.85), width: 0.35)
            .fixedSize()
    }
}

// MARK: - Samples

enum Variant: String, CaseIterable { case A, B, C }

struct Sample {
    let text: String
    let percent: Double?
    let name: String
    let tone: Tone
    let appPalette: HeartPalette
}

let rowFresh = [
    Sample(text: "30%", percent: 30, name: "Codex", tone: .codex, appPalette: .codex),
    Sample(text: "89%", percent: 89, name: "Claude", tone: .claude, appPalette: .claude),
    Sample(text: "100%", percent: 100, name: "AGY", tone: .antigravity, appPalette: .antigravity)
]
let rowEdge = [
    Sample(text: "0%", percent: 0, name: "Codex", tone: .codex, appPalette: .codex),
    Sample(text: "61%", percent: 61, name: "Claude", tone: .stale, appPalette: .stale),   // stale: last value, grey
    Sample(text: "?", percent: nil, name: "AGY", tone: .stale, appPalette: .stale)        // no data (app hides it today)
]

struct Cell: View {
    let variant: Variant
    let sample: Sample
    let dark: Bool

    var body: some View {
        switch variant {
        case .A: current
        case .B: styled { SoftHeart(fraction: sample.percent.map { $0 / 100 }, tone: sample.tone, width: MenuBarHeart.width) }
        case .C: styled { GlassHeart(fraction: sample.percent.map { $0 / 100 }, tone: sample.tone, width: MenuBarHeart.width) }
        }
    }

    // A: the app's MenuBarHeart untouched; "?" mirrors its styling (the app has no "?" path).
    @ViewBuilder private var current: some View {
        if let percent = sample.percent {
            MenuBarHeart(percent: percent, name: sample.name, palette: sample.appPalette)
        } else {
            VStack(spacing: MenuBarHeart.nameSpacing) {
                JellyHeart(fraction: nil, palette: sample.appPalette, width: MenuBarHeart.width) {
                    Text("?").font(.system(size: MenuBarHeart.percentFontSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(sample.appPalette.ink).fixedSize()
                        .shadow(color: .white.opacity(0.9), radius: 0.4).offset(y: -0.5)
                }
                Text(sample.name).font(.system(size: MenuBarHeart.nameFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(sample.appPalette.rim).lineLimit(1).fixedSize()
                    .padding(.bottom, -MenuBarHeart.nameBottomTrim)
            }
        }
    }

    // B/C: same spacing constants as the app; text sits above the heart so the heart's shadow cannot blur it.
    private func styled<H: View>(@ViewBuilder heart: () -> H) -> some View {
        VStack(spacing: MenuBarHeart.nameSpacing) {
            heart().overlay { NumberLabel(text: sample.text, ink: sample.tone.ink) }
            Text(sample.name).font(.system(size: MenuBarHeart.nameFontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(dark ? sample.tone.nameOnDark : sample.tone.nameOnLight)
                .lineLimit(1).fixedSize()
                .padding(.bottom, -MenuBarHeart.nameBottomTrim)
        }
    }
}

struct Row: View {
    let variant: Variant
    let samples: [Sample]
    let dark: Bool
    var body: some View {
        HStack(alignment: .top, spacing: MenuBarHeartRow.heartSpacing) {
            ForEach(samples.indices, id: \.self) { Cell(variant: variant, sample: samples[$0], dark: dark) }
        }
        .padding(.horizontal, 1)
    }
}

// MARK: - Rasterising like the app (bitmap bounds clip the same way)

/// B/C snap the bitmap to whole points (22pt high, width rounded up) so the menu bar never resamples it.
@MainActor
func rowImage(_ variant: Variant, _ samples: [Sample], dark: Bool, scale: CGFloat) -> NSImage {
    let scheme: ColorScheme = dark ? .dark : .light
    let natural = ImageRenderer(content: Row(variant: variant, samples: samples, dark: dark).environment(\.colorScheme, scheme))
    natural.scale = scale
    guard variant != .A, let size = natural.nsImage?.size else { return natural.nsImage! }
    let snapped = ImageRenderer(content: Row(variant: variant, samples: samples, dark: dark)
        .frame(width: size.width.rounded(.up), height: 22)
        .environment(\.colorScheme, scheme))
    snapped.scale = scale
    return snapped.nsImage!
}

let lightBar = Color(white: 0.93)
let darkBar = Color(white: 0.13)

struct Strip: View {
    let variant: Variant
    let dark: Bool
    let pixelScale: CGFloat
    let zoom: CGFloat
    var body: some View {
        HStack(spacing: 14 * zoom) {
            ForEach([rowFresh, rowEdge].indices, id: \.self) { i in
                let image = rowImage(variant, [rowFresh, rowEdge][i], dark: dark, scale: pixelScale)
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

struct Sheet: View {
    let pixelScale: CGFloat
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 10 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold)).foregroundStyle(.black)
            ForEach(Variant.allCases, id: \.self) { variant in
                HStack(spacing: 12 * u) {
                    VStack(spacing: 2 * u) {
                        Text(variant.rawValue).font(.system(size: 14 * u, weight: .bold))
                        Text(variant == .A ? "현재" : variant == .B ? "소프트 3D" : "글래스 젤리")
                            .font(.system(size: 7 * u, weight: .medium))
                    }
                    .foregroundStyle(.black).frame(width: 44 * u)
                    VStack(alignment: .leading, spacing: 0) {
                        Strip(variant: variant, dark: false, pixelScale: pixelScale, zoom: zoom)
                        Strip(variant: variant, dark: true, pixelScale: pixelScale, zoom: zoom)
                    }
                }
            }
            Text("왼쪽 묶음: 30% · 89% · 100%   오른쪽 묶음: 0% · 이전 데이터(회색 61%) · 데이터 없음(?)")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .padding(12 * u)
        .background(Color.white)
    }
}

/// The same B/C heart at several live fractions, to show the gauge is a view, not a fixed PNG.
struct GaugeSheet: View {
    var body: some View {
        let zoom: CGFloat = 5
        let steps: [Double] = [0, 0.25, 0.5, 0.75, 1]
        VStack(alignment: .leading, spacing: 14) {
            Text("잔여율에 따른 채움 (Retina 2배율 픽셀을 보간 없이 2.5배 확대)").font(.system(size: 14, weight: .semibold))
            ForEach(["B", "C"], id: \.self) { kind in
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 18) {
                        Text("\(kind) \(dark ? "다크" : "라이트")").font(.system(size: 12, weight: .medium)).frame(width: 60)
                        ForEach(steps, id: \.self) { f in
                            let heart = kind == "B"
                                ? AnyView(SoftHeart(fraction: f, tone: .claude, width: MenuBarHeart.width))
                                : AnyView(GlassHeart(fraction: f, tone: .claude, width: MenuBarHeart.width))
                            let renderer = ImageRenderer(content: heart.padding(1))
                            let _ = { renderer.scale = 2 }()
                            let image = renderer.nsImage!
                            Image(nsImage: image).interpolation(.none).resizable()
                                .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                        }
                    }
                    .padding(8)
                    .background(dark ? darkBar : lightBar)
                    .foregroundStyle(dark ? Color.white : .black)
                }
            }
        }
        .padding(16)
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
struct Render {
    @MainActor static func main() {
        save(Sheet(pixelScale: 2, zoom: 1, caption: "Retina 2배율 실제 픽셀 (메뉴 막대에서 보이는 크기)"), scale: 2, to: "styles-2x-retina.png")
        save(Sheet(pixelScale: 2, zoom: 5, caption: "확대: Retina 2배율 픽셀을 보간 없이 2.5배 확대 (= 5배)"), scale: 1, to: "styles-zoom5x-from-retina.png")
        save(Sheet(pixelScale: 1, zoom: 1, caption: "참고: 1배율(비 Retina) 실제 픽셀"), scale: 1, to: "styles-1x.png")
        save(GaugeSheet(), scale: 1, to: "gauge-steps.png")

        for variant in Variant.allCases {
            for (label, row) in [("fresh", rowFresh), ("edge", rowEdge)] {
                let image = rowImage(variant, row, dark: false, scale: 2)
                var rect = CGRect(origin: .zero, size: image.size)
                let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
                func rowAlpha(_ y: Int) -> Double { (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0 }.max() ?? 0 }
                func colAlpha(_ x: Int) -> Double { (0..<rep.pixelsHigh).map { rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0 }.max() ?? 0 }
                print("\(variant.rawValue) \(label): \(image.size.width)x\(image.size.height)pt \(rep.pixelsWide)x\(rep.pixelsHigh)px, edge alpha top \(String(format: "%.2f", rowAlpha(0))) bottom \(String(format: "%.2f", rowAlpha(rep.pixelsHigh - 1))) left \(String(format: "%.2f", colAlpha(0))) right \(String(format: "%.2f", colAlpha(rep.pixelsWide - 1)))")
            }
        }
    }
}
