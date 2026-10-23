// Numeric style typography study: current (heavy, 0.7pt gaps, 1.5pt drop) vs lighter weights, wider
// "/" gaps and a larger 5h/7d drop. Uses the app's MenuBarNumericImage. Run ./run-typography.sh.
import AppKit
import SwiftUI

typealias L = MenuBarNumericImage.Layout
func item(_ p: HeartGaugeProvider, _ a: Double?, _ b: Double?, stale: Bool = false) -> NumericGaugeItem {
    NumericGaugeItem(provider: p, primary: a, secondary: b, hasSecondarySlot: p != .antigravity, stale: stale)
}
let rows = [
    [item(.codex, 97, 89), item(.claude, 28, 91), item(.antigravity, 54, nil)],
    [item(.codex, 100, 100), item(.claude, 9, 100), item(.antigravity, 0, nil, stale: true)],
    [item(.codex, 0, 0)]
]
func variant(_ pw: NSFont.Weight, _ sw: NSFont.Weight, _ nw: NSFont.Weight, gap: CGFloat, drop: CGFloat) -> L {
    var l = L(); l.primaryWeight = pw; l.secondaryWeight = sw; l.nameWeight = nw; l.separatorGap = gap; l.drop = drop
    l.separatorWeight = sw == .heavy ? .semibold : .medium
    return l
}
let typographyVariants: [(String, L)] = [
    ("현재: Heavy · 간격 0.7 · 1.5pt", .first),
    ("A: Semibold · 1.2 · 2.0pt", variant(.semibold, .semibold, .semibold, gap: 1.2, drop: 2.0)),
    ("B: Medium · 1.2 · 2.0pt", variant(.medium, .medium, .medium, gap: 1.2, drop: 2.0)),
    ("C: 5h Semibold/7d Medium · 1.2 · 2.0pt", variant(.semibold, .medium, .medium, gap: 1.2, drop: 2.0)),
    ("D: C + 간격 1.5", variant(.semibold, .medium, .medium, gap: 1.5, drop: 2.0)),
    ("E: C + 2.5pt", variant(.semibold, .medium, .medium, gap: 1.2, drop: 2.5)),
]
/// Before/after sheet: the first design and the applied one (Layout.standard).
var previous: L { var l = L.standard; l.separatorGap = 1.7; l.columnSpacing = 12; return l }
let applied: [(String, L)] = [("변경 전: / 1.7pt · 서비스 12pt", previous), ("적용: / 1.2pt · 서비스 16pt", .standard)]

enum Bar: CaseIterable {
    case light, dark, sky
    var color: Color { self == .light ? Color(white: 0.93) : self == .dark ? Color(white: 0.13) : Color(red: 0.80, green: 0.91, blue: 0.98) }
    var dark: Bool { self == .dark }
}

@MainActor func image(_ items: [NumericGaugeItem], _ bar: Bar, _ l: L) -> NSImage {
    NSImage(cgImage: MenuBarNumericImage.render(items, dark: bar.dark, scale: 2, layout: l)!, size: MenuBarNumericImage.size(items, layout: l))
}

struct Sheet: View {
    let zoom: CGFloat
    let caption: String
    var variants: [(String, L)] = typographyVariants
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 6 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach(variants.indices, id: \.self) { v in
                HStack(spacing: 10 * u) {
                    Text(variants[v].0).font(.system(size: 8 * u, weight: .bold)).frame(width: 120 * u, alignment: .leading)
                    VStack(spacing: 2 * u) {
                        ForEach(Bar.allCases, id: \.self) { bar in
                            HStack(spacing: 14 * zoom) {
                                ForEach(rows.indices, id: \.self) { r in
                                    let img = image(rows[r], bar, variants[v].1)
                                    Image(nsImage: img).interpolation(.none).resizable()
                                        .frame(width: img.size.width * zoom, height: img.size.height * zoom)
                                }
                                // Neutral reference: the menu bar's default text (13pt regular).
                                Text("CPU 23%  RAM 61%  12:34").font(.system(size: 13 * zoom))
                                    .foregroundStyle(bar.dark ? Color.white : .black)
                            }
                            .padding(.horizontal, 10 * zoom).frame(height: 24 * zoom).background(bar.color)
                        }
                    }
                }
            }
            Text("97/89 · 28/91 · AGY 54 | 100/100 · 9/100 · AGY 이전 데이터 0 | 0/0 — 오른쪽 회색 글씨는 메뉴 막대 기본 13pt Regular 참고용")
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

/// Visual gaps between 5h / "/" / 7d inks, digits→name gap, edges, widths.
@MainActor func report(_ name: String, _ l: L) {
    var out: [String] = []
    for items in rows {
        let cg = MenuBarNumericImage.render(items, dark: false, scale: 2, layout: l)!
        var b = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &b, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let w = cg.width, h = cg.height
        func a(_ x: Int, _ y: Int) -> UInt8 { b[(y * w + x) * 4 + 3] }
        let edge = max((0..<w).map { max(a($0, 0), a($0, h - 1)) }.max()!, (0..<h).map { max(a(0, $0), a(w - 1, $0)) }.max()!)
        var cols: [String] = []
        for it in items {
            let col = MenuBarNumericImage.column(it, layout: l, color: .black)
            let digits = Array(col.runs.dropLast()), nm = col.runs.last!
            func box(_ r: MenuBarNumericImage.Run) -> CGRect {
                let i = MenuBarNumericImage.ink(r.line)
                return CGRect(x: r.x + i.minX, y: r.baseline - i.maxY, width: i.width, height: i.height)
            }
            let boxes = digits.map(box), n = box(nm)
            let gaps = zip(boxes, boxes.dropFirst()).map { String(format: "%.2f", $1.minX - $0.maxX) }.joined(separator: "/")
            let lowest = boxes.map(\.maxY).max()!, top = boxes.map(\.minY).min()!
            cols.append(String(format: "%@ %@ gaps[%@] ink %.1f…%.1f name %.1f…%.1f d→n %.2f",
                               it.name, NumericGaugeItem.text(it.primary) + (it.hasSecondarySlot ? "/" + NumericGaugeItem.text(it.secondary) : ""),
                               gaps.isEmpty ? "-" : gaps, top, lowest, n.minY, n.maxY, n.minY - lowest))
        }
        out.append("\(Int(MenuBarNumericImage.size(items, layout: l).width))pt edge \(edge) | " + cols.joined(separator: " | "))
    }
    print("== \(name)"); out.forEach { print("   " + $0) }
}

@main struct Main { @MainActor static func main() {
    for v in applied { report(v.0, v.1) }
    save(Sheet(zoom: 1, caption: "숫자형 서비스 간격 12 → 16pt, / 1.2pt 복원 — 앱 렌더링, Retina 2배율 실제 픽셀", variants: applied), scale: 2, "78-numeric-column-spacing-actual-2x.png")
    save(Sheet(zoom: 3, caption: "서비스 간격 12 → 16pt 확대 — Retina 2배율 픽셀 보간 없이 1.5배 (= 3배)", variants: applied), scale: 1, "79-numeric-column-spacing-zoom3x.png")
}}
