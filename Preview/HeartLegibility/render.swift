// Legibility comparison for the menu bar hearts (A: current, B: contrast, C: number-first).
// Preview-only: not part of the Xcode project. Run ./run.sh from this folder.
import AppKit
import SwiftUI

// MARK: - Shared sample data

struct Sample {
    let text: String
    let percent: Double?
    let name: String
    let palette: HeartPalette
    let tone: NameTone
}

enum NameTone { case codex, claude, antigravity, stale }

let rowFresh = [
    Sample(text: "30%", percent: 30, name: "Codex", palette: .codex, tone: .codex),
    Sample(text: "89%", percent: 89, name: "Claude", palette: .claude, tone: .claude),
    Sample(text: "100%", percent: 100, name: "AGY", palette: .antigravity, tone: .antigravity)
]
let rowEdge = [
    Sample(text: "0%", percent: 0, name: "Codex", palette: .codex, tone: .codex),
    Sample(text: "61%", percent: 61, name: "Claude", palette: .stale, tone: .stale),
    // The app never shows "?" in the menu bar today; included only to test the glyph.
    Sample(text: "?", percent: nil, name: "AGY", palette: .stale, tone: .stale)
]

func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255)
}

// Same hex values as HeartPalette; B/C pick a darker or lighter name tone per menu bar appearance.
func nameColor(_ tone: NameTone, dark: Bool) -> Color {
    switch (tone, dark) {
    case (.codex, false): rgb(0xC2413D)
    case (.claude, false): rgb(0x5E3FA8)
    case (.antigravity, false): rgb(0x1F6FA3)
    case (.stale, false): rgb(0x5E5E66)
    case (.codex, true): rgb(0xFFB3A7)
    case (.claude, true): rgb(0xD7C6FF)
    case (.antigravity, true): rgb(0xB5E2FF)
    case (.stale, true): rgb(0xD4D4D9)
    }
}

/// Crisp hairline outline: the text stamped at 8 offsets instead of a blurred shadow.
/// The text must not carry its own color, otherwise the outline stamps inherit it and smear.
struct Outlined: View {
    let text: Text
    let fill: Color
    let outline: Color
    let width: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * .pi / 4
                text.foregroundStyle(outline)
                    .offset(x: CGFloat(cos(angle)) * width, y: CGFloat(sin(angle)) * width)
            }
            text.foregroundStyle(fill)
        }
    }
}

// MARK: - Variants

enum Variant: String, CaseIterable { case A, B, C }

struct HeartCell: View {
    let variant: Variant
    let sample: Sample
    let dark: Bool

    var body: some View {
        switch variant {
        case .A: currentDesign
        case .B: contrastDesign
        case .C: numberFirstDesign
        }
    }

    // A: the app's MenuBarHeart, untouched. "?" mirrors its styling because the app has no "?" path.
    @ViewBuilder private var currentDesign: some View {
        if let percent = sample.percent {
            MenuBarHeart(percent: percent, name: sample.name, palette: sample.palette)
        } else {
            VStack(spacing: MenuBarHeart.nameSpacing) {
                JellyHeart(fraction: nil, palette: sample.palette, width: MenuBarHeart.width) {
                    Text("?").font(.system(size: MenuBarHeart.percentFontSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(sample.palette.ink).fixedSize()
                        .shadow(color: .white.opacity(0.9), radius: 0.4).offset(y: -0.5)
                }
                Text(sample.name).font(.system(size: MenuBarHeart.nameFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(sample.palette.rim).lineLimit(1).fixedSize()
                    .padding(.bottom, -MenuBarHeart.nameBottomTrim)
            }
        }
    }

    // B: same sizes; text drawn above the heart (so the heart's drop shadow no longer blurs it),
    // one weight step heavier, hairline outline instead of a blurred halo, appearance-aware names.
    private var contrastDesign: some View {
        let size = sample.text.count > 3 ? MenuBarHeart.wideFontSize : MenuBarHeart.percentFontSize
        let number = Text(sample.text).font(.system(size: size, weight: .black, design: .rounded))
            .monospacedDigit().tracking(-0.2)
        return VStack(spacing: MenuBarHeart.nameSpacing) {
            JellyHeart(fraction: sample.percent.map { $0 / 100 }, palette: sample.palette, width: MenuBarHeart.width)
                .overlay {
                    Outlined(text: number, fill: sample.palette.ink, outline: .white.opacity(0.85), width: 0.35)
                        .fixedSize().offset(y: -0.5)
                }
            name(weight: .heavy)
        }
    }

    // C: digits enlarged and "%" shrunk so the digits get the space; a faint local glow calms the
    // highlight and liquid line behind the number. Names as in B.
    private var numberFirstDesign: some View {
        let digits = sample.text.hasSuffix("%") ? String(sample.text.dropLast()) : sample.text
        let wide = digits.count >= 3
        let digitSize: CGFloat = wide ? 6.1 : 7.3
        let percentSize: CGFloat = wide ? 4.3 : 4.8
        var number = Text(digits).font(.system(size: digitSize, weight: .black, design: .rounded))
        if sample.text.hasSuffix("%") {
            number = number + Text("%").font(.system(size: percentSize, weight: .heavy, design: .rounded))
        }
        number = number.tracking(-0.25).monospacedDigit()
        return VStack(spacing: MenuBarHeart.nameSpacing) {
            JellyHeart(fraction: sample.percent.map { $0 / 100 }, palette: sample.palette, width: MenuBarHeart.width)
                .overlay {
                    ZStack {
                        Ellipse().fill(.white.opacity(0.42)).frame(width: 13, height: 7).blur(radius: 1.2)
                        Outlined(text: number, fill: sample.palette.ink, outline: .white.opacity(0.85), width: 0.35)
                            .fixedSize()
                    }
                    .offset(y: 0)
                }
            name(weight: .heavy)
        }
    }

    private func name(weight: Font.Weight) -> some View {
        Text(sample.name).font(.system(size: MenuBarHeart.nameFontSize, weight: weight, design: .rounded))
            .foregroundStyle(nameColor(sample.tone, dark: dark))
            .lineLimit(1).fixedSize()
            .padding(.bottom, -MenuBarHeart.nameBottomTrim)
    }
}

struct Row: View {
    let variant: Variant
    let samples: [Sample]
    let dark: Bool
    var topPadding: CGFloat = 0
    var body: some View {
        HStack(alignment: .top, spacing: MenuBarHeartRow.heartSpacing) {
            ForEach(samples.indices, id: \.self) { HeartCell(variant: variant, sample: samples[$0], dark: dark) }
        }
        .padding(.horizontal, 1)
        .padding(.top, topPadding)
    }
}

// MARK: - Rendering (each row is rasterised like MenuBarHeartImage, so its bounds clip the same way)

@MainActor
func rowImage(_ variant: Variant, _ samples: [Sample], dark: Bool, scale: CGFloat, topPadding: CGFloat = 0) -> NSImage {
    let renderer = ImageRenderer(content: Row(variant: variant, samples: samples, dark: dark, topPadding: topPadding)
        .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = scale
    return renderer.nsImage!
}

let lightBar = Color(white: 0.93)
let darkBar = Color(white: 0.13)

/// One menu-bar strip: rows rendered at `pixelScale`, magnified with nearest-neighbour to `zoom`.
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
        VStack(alignment: .leading, spacing: 10 * max(1, zoom / 2)) {
            Text(caption).font(.system(size: 11 * max(1, zoom / 2), weight: .semibold)).foregroundStyle(.black)
            ForEach(Variant.allCases, id: \.self) { variant in
                HStack(spacing: 12 * max(1, zoom / 2)) {
                    Text(variant.rawValue).font(.system(size: 14 * max(1, zoom / 2), weight: .bold)).foregroundStyle(.black)
                        .frame(width: 18 * max(1, zoom / 2))
                    VStack(alignment: .leading, spacing: 0) {
                        Strip(variant: variant, dark: false, pixelScale: pixelScale, zoom: zoom)
                        Strip(variant: variant, dark: true, pixelScale: pixelScale, zoom: zoom)
                    }
                }
            }
        }
        .padding(12 * max(1, zoom / 2))
        .background(Color.white)
    }
}

/// Top edge of the current design: as rendered (clipped) vs. with 0.5pt headroom.
struct ClipSheet: View {
    var body: some View {
        let zoom: CGFloat = 8
        VStack(alignment: .leading, spacing: 12) {
            ForEach([(0.0, "현재(잘림): 이미지 위 끝에서 테두리 절반이 잘림"), (0.5, "참고: 위 0.5pt 여유를 준 경우 (높이 22.49pt, 22pt 초과)")], id: \.0) { pad, label in
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                let image = rowImage(.A, rowFresh, dark: false, scale: 2, topPadding: pad)
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    .background(lightBar)
                    .overlay(alignment: .top) { Rectangle().fill(.red).frame(height: 1) }
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
        // Pixel-exact sheets: rendered at the target pixel density, no resampling.
        save(Sheet(pixelScale: 1, zoom: 1, caption: "1배율 (비 Retina 화면의 실제 픽셀)"), scale: 1, to: "compare-1x.png")
        save(Sheet(pixelScale: 2, zoom: 1, caption: "2배율 (Retina 메뉴 막대의 실제 픽셀)"), scale: 2, to: "compare-2x-retina.png")
        // Magnified sheets: the real 1x / 2x pixels blown up without smoothing, so zoom cannot flatter a variant.
        save(Sheet(pixelScale: 2, zoom: 5, caption: "확대: Retina 2배율 픽셀을 보간 없이 2.5배 확대 (= 5배)"), scale: 1, to: "compare-zoom5x-from-retina.png")
        save(Sheet(pixelScale: 1, zoom: 5, caption: "확대: 1배율 픽셀을 보간 없이 5배 확대"), scale: 1, to: "compare-zoom5x-from-1x.png")
        save(ClipSheet(), scale: 1, to: "top-rim-clip.png")

        for variant in Variant.allCases {
            for (label, row) in [("fresh", rowFresh), ("edge", rowEdge)] {
                let image = rowImage(variant, row, dark: false, scale: 2)
                var rect = CGRect(origin: .zero, size: image.size)
                let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
                func rowAlpha(_ y: Int) -> Double {
                    (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0 }.max() ?? 0
                }
                print("\(variant.rawValue) \(label): \(image.size.width)x\(image.size.height)pt, top-edge alpha \(String(format: "%.2f", rowAlpha(0))), bottom-edge alpha \(String(format: "%.2f", rowAlpha(rep.pixelsHigh - 1)))")
            }
        }
    }
}
