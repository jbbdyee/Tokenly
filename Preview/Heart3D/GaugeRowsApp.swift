// Renders the app's own bear and heart rows (MenuBarBearImage / MenuBarHeartImage, unchanged) and
// measures digits, names and edges. Compiled with the app's sources read-only. Run ./run-gauge-rows.sh.
import AppKit
import SwiftUI

func alpha(_ image: CGImage) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &b, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 3, to: b.count, by: 4).map { b[$0] }
}

func clear(_ like: CGImage) -> CGImage {
    CGContext(data: nil, width: like.width, height: like.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

/// Same icon with parts removed, to isolate bodies, digits or names.
func variant(_ i: GaugeIcon, body: Bool, digits: Bool, name: Bool) -> GaugeIcon {
    GaugeIcon(body: body ? i.body : clear(i.body), bodyFrame: i.bodyFrame, numberCenter: i.numberCenter,
              nameCenterY: i.nameCenterY, text: digits ? i.text : "", digitSize: i.digitSize, style: i.style,
              name: name ? i.name : "", outlineTone: i.outlineTone)
}

@MainActor
func measure(_ style: String, _ icons: [GaugeIcon], column: CGFloat) -> [String] {
    let scale = 2
    func render(_ list: [GaugeIcon]) -> (CGImage, [UInt8]) {
        let image = MenuBarGaugeRow.render(list, columnWidth: column, scale: scale, dark: false, strongOutline: false)!
        return (image, alpha(image))
    }
    let (bodiesImage, bodies) = render(icons.map { variant($0, body: true, digits: false, name: false) })
    let (_, digits) = render(icons.map { variant($0, body: false, digits: true, name: false) })
    let (_, names) = render(icons.map { variant($0, body: false, digits: false, name: true) })
    let w = bodiesImage.width, h = bodiesImage.height
    var lines: [String] = []
    for (index, icon) in icons.enumerated() {
        let x0 = Int(MenuBarGaugeRow.columnX(index, columnWidth: column) * 2), x1 = x0 + Int(column * 2)
        func box(_ a: [UInt8]) -> (Int, Int, Int, Int)? {
            var r: (Int, Int, Int, Int)? = nil
            for y in 0..<h { for x in max(0, x0 - 6)..<min(w, x1 + 6) where a[y * w + x] > 25 {
                r = r.map { (min($0.0, x), max($0.1, x), min($0.2, y), max($0.3, y)) } ?? (x, x, y, y) } }
            return r
        }
        guard let d = box(digits), let n = box(names) else { continue }
        // Clearance: Chebyshev distance from digit ink to the nearest pixel outside the silhouette.
        var clearance = 99
        for y in d.2...d.3 { for x in d.0...d.1 where digits[y * w + x] > 25 {
            var k = 0
            while k < 12, (-k...k).allSatisfy({ dy in (-k...k).allSatisfy { dx in
                let xx = x + dx, yy = y + dy; return xx >= 0 && yy >= 0 && xx < w && yy < h && bodies[yy * w + xx] >= 128 } }) { k += 1 }
            clearance = min(clearance, k - 1) } }
        let cx = Double(d.0 + d.1 + 1) / 4 - Double(x0) / 2, cy = Double(d.2 + d.3 + 1) / 4
        let nameCx = Double(n.0 + n.1 + 1) / 4 - Double(x0) / 2
        lines.append(String(format: "%@ %-6@ %-4@ digits centre off (%+.2f, %+.2f)pt, clearance %dpx, digit→name gap %.1fpt | name ink %.1f×%.1fpt, centre off %+.2fpt, rows %d…%d",
                            style as NSString, icon.name as NSString, icon.text as NSString,
                            cx - Double(icon.numberCenter.x), cy - Double(icon.numberCenter.y), clearance,
                            Double(n.2 - d.3 - 1) / 2, Double(n.1 - n.0 + 1) / 2, Double(n.3 - n.2 + 1) / 2,
                            nameCx - Double(column / 2), n.2, n.3))
    }
    return lines
}

enum Bar: CaseIterable {
    case light, dark, sky
    var color: Color { self == .light ? Color(white: 0.93) : self == .dark ? Color(white: 0.13) : Color(red: 0.80, green: 0.91, blue: 0.98) }
    var dark: Bool { self == .dark }
    var label: String { self == .light ? "라이트" : self == .dark ? "다크" : "밝은 하늘색" }
}

let bearRows: [[MenuBarBearItem]] = [
    [.init(percent: 54, name: "Codex", service: "codex"), .init(percent: 89, name: "Claude", service: "claude"),
     .init(percent: 100, name: "AGY", service: "antigravity")],
    [.init(percent: 0, name: "Codex", service: "codex"), .init(percent: 9, name: "Claude", service: "claude"),
     .init(percent: 61, name: "AGY", service: "stale")]
]
let heartRows: [[MenuBarHeartItem]] = [
    [.init(percent: 54, name: "Codex", palette: .codex), .init(percent: 89, name: "Claude", palette: .claude),
     .init(percent: 100, name: "AGY", palette: .antigravity)],
    [.init(percent: 0, name: "Codex", palette: .codex), .init(percent: 9, name: "Claude", palette: .claude),
     .init(percent: 61, name: "AGY", palette: .stale)]
]

@MainActor
func rowImage(_ style: String, _ index: Int, _ bar: Bar) -> NSImage {
    style == "bear" ? MenuBarBearImage.make(bearRows[index], dark: bar.dark)! : MenuBarHeartImage.make(heartRows[index], dark: bar.dark)!
}

struct Sheet: View {
    let styles: [String]
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach(styles, id: \.self) { style in
                HStack(spacing: 10 * u) {
                    Text(style == "bear" ? "곰돌이형" : "하트형").font(.system(size: 10 * u, weight: .bold)).frame(width: 46 * u, alignment: .leading)
                    VStack(spacing: 4 * u) {
                        ForEach(Bar.allCases, id: \.self) { bar in
                            HStack(spacing: 14 * zoom) {
                                ForEach(0..<2, id: \.self) { i in
                                    let img = rowImage(style, i, bar)
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
            Text("앱 렌더링 코드 출력 · 각 줄: Codex 54 · Claude 89 · AGY 100 | Codex 0 · Claude 9 · AGY 이전 데이터(회색 61) · 89×22pt · 간격 12pt")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black).padding(12 * u).background(Color.white)
    }
}

@MainActor
func save<V: View>(_ view: V, scale: CGFloat, to name: String) {
    let r = ImageRenderer(content: view); r.scale = scale
    try! NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
    print("wrote", name, r.cgImage!.width, "x", r.cgImage!.height, "px")
}

@main
struct GaugeRowsMain {
    @MainActor static func main() {
        for value in [0.0, 9, 54, 89, 100] {
            let bears = MenuBarBearImage.icons(["codex", "claude", "antigravity", "stale"].map {
                MenuBarBearItem(percent: value, name: $0 == "codex" ? "Codex" : $0 == "claude" ? "Claude" : $0 == "stale" ? "Codex" : "AGY", service: $0)
            }, scale: 2)!
            measure("bear ", bears, column: MenuBarBearImage.frameWidth).forEach { print($0) }
            let hearts = MenuBarHeartImage.icons([HeartPalette.codex, .claude, .antigravity, .stale].enumerated().map {
                MenuBarHeartItem(percent: value, name: ["Codex", "Claude", "AGY", "Codex"][$0.offset], palette: $0.element)
            }, scale: 2)!
            measure("heart", hearts, column: MenuBarHeartImage.columnWidth).forEach { print($0) }
        }
        for style in ["bear", "heart"] {
            for bar in Bar.allCases {
                for i in 0..<2 {
                    let img = rowImage(style, i, bar)
                    var rect = CGRect(origin: .zero, size: img.size)
                    let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
                    let a = alpha(cg), w = cg.width, h = cg.height
                    let edges = [(0..<w).map { a[$0] }.max()!, (0..<w).map { a[(h - 1) * w + $0] }.max()!,
                                 (0..<h).map { a[$0 * w] }.max()!, (0..<h).map { a[$0 * w + w - 1] }.max()!]
                    print("\(style) \(bar.label) row \(i): \(img.size) px \(w)x\(h), edge alpha top/bottom/left/right \(edges)")
                }
            }
        }
        save(Sheet(styles: ["bear"], zoom: 1, caption: "개선 곰돌이형 — 앱 렌더링, Retina 2배율 실제 픽셀"), scale: 2, to: "60-bear-b-app-actual-2x.png")
        save(Sheet(styles: ["heart"], zoom: 1, caption: "개선 하트형 — 앱 렌더링, Retina 2배율 실제 픽셀"), scale: 2, to: "61-heart-b-app-actual-2x.png")
        save(Sheet(styles: ["bear", "heart"], zoom: 1, caption: "곰돌이형 vs 하트형 — 앱 렌더링, Retina 2배율 실제 픽셀"), scale: 2, to: "62-bear-heart-app-actual-2x.png")
        save(Sheet(styles: ["bear", "heart"], zoom: 4, caption: "확대 — Retina 2배율 픽셀 보간 없이 2배 (= 4배)"), scale: 1, to: "63-bear-heart-app-zoom4x.png")
    }
}
