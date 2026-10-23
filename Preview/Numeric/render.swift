// Numeric style study: 5h large/high, 7d smaller/lower, name below. Uses the app's MenuBarNumericImage
// with different Layout values. Compiled with the app's sources read-only. Run ./run.sh.
import AppKit
import SwiftUI

func item(_ p: HeartGaugeProvider, _ a: Double?, _ b: Double?, stale: Bool = false) -> NumericGaugeItem {
    NumericGaugeItem(provider: p, primary: a, secondary: b, hasSecondarySlot: p != .antigravity, stale: stale)
}
let rowA = [item(.codex, 40, 70), item(.claude, 100, 100), item(.antigravity, 9, nil)]
let rowB = [item(.codex, 9, 100), item(.claude, 0, 0), item(.antigravity, 54, nil, stale: true)]

let variants: [(String, MenuBarNumericImage.Layout)] = [
    ("15% 작게 · 1.5pt", .init(secondaryRatio: 0.85, drop: 1.5)),
    ("20% 작게 · 1.5pt", .init(secondaryRatio: 0.80, drop: 1.5)),
    ("25% 작게 · 1.5pt", .init(secondaryRatio: 0.75, drop: 1.5)),
    ("20% 작게 · 1.0pt", .init(secondaryRatio: 0.80, drop: 1.0)),
    ("20% 작게 · 2.0pt", .init(secondaryRatio: 0.80, drop: 2.0)),
]

enum Bar: CaseIterable {
    case light, dark, sky
    var color: Color { self == .light ? Color(white: 0.93) : self == .dark ? Color(white: 0.13) : Color(red: 0.80, green: 0.91, blue: 0.98) }
    var dark: Bool { self == .dark }
}

@MainActor func image(_ items: [NumericGaugeItem], _ bar: Bar, _ layout: MenuBarNumericImage.Layout) -> NSImage {
    NSImage(cgImage: MenuBarNumericImage.render(items, dark: bar.dark, scale: 2, layout: layout)!, size: MenuBarNumericImage.size(items, layout: layout))
}

struct Sheet: View {
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 6 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach(variants.indices, id: \.self) { v in
                HStack(spacing: 10 * u) {
                    Text(variants[v].0).font(.system(size: 9 * u, weight: .bold)).frame(width: 90 * u, alignment: .leading)
                    VStack(spacing: 2 * u) {
                        ForEach(Bar.allCases, id: \.self) { bar in
                            HStack(spacing: 16 * zoom) {
                                ForEach([rowA, rowB].indices, id: \.self) { r in
                                    let img = image([rowA, rowB][r], bar, variants[v].1)
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
            Text("왼쪽: Codex 40/70 · Claude 100/100 · AGY 9(버킷 최저, 5h/7d 없음) | 오른쪽: 9/100 · 0/0 · AGY 이전 데이터 54")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black).padding(12 * u).background(Color.white)
    }
}

@MainActor func save<V: View>(_ v: V, scale: CGFloat, _ name: String) {
    let r = ImageRenderer(content: v); r.scale = scale
    try! NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
    print("wrote", name)
}

/// Overlap/clipping: per column, ink of the 5h, 7d and name runs must not overlap; the bitmap edges stay clear.
@MainActor func check(_ name: String, _ layout: MenuBarNumericImage.Layout) {
    for items in [rowA, rowB] {
        let cg = MenuBarNumericImage.render(items, dark: false, scale: 2, layout: layout)!
        var b = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &b, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let w = cg.width, h = cg.height
        func a(_ x: Int, _ y: Int) -> UInt8 { b[(y * w + x) * 4 + 3] }
        let edge = max((0..<w).map { max(a($0, 0), a($0, h - 1)) }.max()!, (0..<h).map { max(a(0, $0), a(w - 1, $0)) }.max()!)
        var gaps: [String] = []
        for it in items {
            let col = MenuBarNumericImage.column(it, layout: layout, color: .black)
            let digitRuns = col.runs.dropLast(), name = col.runs.last!
            let lowest = digitRuns.map { $0.baseline - MenuBarNumericImage.ink($0.line).minY }.max()!
            let nameTop = name.baseline - MenuBarNumericImage.ink(name.line).maxY
            let topInk = digitRuns.map { $0.baseline - MenuBarNumericImage.ink($0.line).maxY }.min()!
            let nameBottom = name.baseline - MenuBarNumericImage.ink(name.line).minY
            gaps.append(String(format: "%@ %@/%@ digits %.1f…%.1f name %.1f…%.1f gap %.2f",
                               it.name, NumericGaugeItem.text(it.primary), NumericGaugeItem.text(it.secondary), topInk, lowest, nameTop, nameBottom, nameTop - lowest))
        }
        print(name, MenuBarNumericImage.size(items, layout: layout), "edge alpha", edge, "|", gaps.joined(separator: " | "))
    }
}

@main struct Main { @MainActor static func main() {
    for v in variants { check(v.0, v.1) }
    save(Sheet(zoom: 1, caption: "숫자형 위계 비교 — Retina 2배율 실제 픽셀"), scale: 2, "70-numeric-hierarchy-actual-2x.png")
    save(Sheet(zoom: 4, caption: "확대 — Retina 2배율 픽셀 보간 없이 2배 (= 4배)"), scale: 1, "71-numeric-hierarchy-zoom4x.png")
}}
