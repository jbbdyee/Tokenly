// Digits-only bear numbers: measures centring and edge clearance on the app's own rendering, and
// writes actual-size light/dark sheets. Compiled with the app's sources read-only. Run ./run-numbers.sh.
import AppKit
import SwiftUI

func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// Ink = pixels where the bear with its number differs from the bare gauge image.
@MainActor
func measure(_ item: MenuBarBearItem) -> String {
    let scale = 2, w = 36, h = 32
    let set = BearAssets.set(service: item.service, scale: scale)!
    let gauge = BearGaugeCompositor.image(set, fraction: item.percent.map { $0 / 100 })!
    // The number alone on a transparent layer: its alpha is the exact ink, whatever the bear behind it.
    let clear = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let numberOnly = BearNumber.draw(BearNumber.text(item.percent), style: BearNumber.style(item), on: clear, scale: scale)!
    let a = rgba(numberOnly), base = rgba(gauge)
    var minX = w, maxX = -1, minY = h, maxY = -1, clearance = Int.max
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && base[(y * w + x) * 4 + 3] >= 128 }
    for y in 0..<h {
        for x in 0..<w {
            guard a[(y * w + x) * 4 + 3] > 25 else { continue }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            // Distance (px, Chebyshev) to the nearest pixel outside the silhouette.
            var d = 0
            while d < 20, (-d...d).allSatisfy({ dx in (-d...d).allSatisfy { dy in inside(x + dx, y + dy) } }) { d += 1 }
            clearance = min(clearance, d)
        }
    }
    let cx = Double(minX + maxX + 1) / 2 / Double(scale), cy = Double(minY + maxY + 1) / 2 / Double(scale)
    let target = BearNumber.center
    return String(format: "%-11@ %-4@ ink centre (%.2f, %.2f)pt  target (%.2f, %.2f)  off (%+.2f, %+.2f)pt  width %.1fpt  clearance %dpx",
                  item.service as NSString, BearNumber.text(item.percent) as NSString, cx, cy, target.x, target.y,
                  cx - target.x, cy - target.y, Double(maxX - minX + 1) / 2, clearance - 1)
}

let rows: [[MenuBarBearItem]] = [
    [MenuBarBearItem(percent: 54, name: "Codex", service: "codex"),
     MenuBarBearItem(percent: 89, name: "Claude", service: "claude"),
     MenuBarBearItem(percent: 100, name: "AGY", service: "antigravity")],
    [MenuBarBearItem(percent: 0, name: "Codex", service: "codex"),
     MenuBarBearItem(percent: 9, name: "Claude", service: "claude"),
     MenuBarBearItem(percent: 61, name: "AGY", service: "stale")],
    [MenuBarBearItem(percent: 100, name: "Codex", service: "codex")]
]

struct Sheet: View {
    let zoom: CGFloat
    let caption: String
    var body: some View {
        let u = max(1, zoom / 2)
        VStack(alignment: .leading, spacing: 8 * u) {
            Text(caption).font(.system(size: 11 * u, weight: .semibold))
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 14 * zoom) {
                    ForEach(rows.indices, id: \.self) { i in
                        let image = MenuBarBearImage.make(rows[i], dark: dark)!
                        Image(nsImage: image).interpolation(.none).resizable()
                            .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    }
                    Text("12:34").font(.system(size: 13 * zoom)).foregroundStyle(dark ? Color.white : .black)
                }
                .padding(.horizontal, 10 * zoom)
                .frame(height: 24 * zoom)
                .background(dark ? Color(white: 0.13) : Color(white: 0.93))
            }
            Text("54 · 89 · 100  |  0 · 9 · 이전 데이터(회색 61)  |  1개(100) — 곰돌이 18×16pt, 간격 12pt, 높이 22pt, 강함 외곽선")
                .font(.system(size: 8 * u)).foregroundStyle(.gray)
        }
        .foregroundStyle(.black)
        .padding(12 * u)
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
struct NumbersMain {
    @MainActor static func main() {
        for service in ["codex", "claude", "antigravity", "stale"] {
            for value in [0.0, 9, 54, 89, 100] { print(measure(MenuBarBearItem(percent: value, name: "", service: service))) }
        }
        print(measure(MenuBarBearItem(percent: nil, name: "", service: "stale")))
        for row in rows { print("row of \(row.count):", MenuBarBearImage.make(row, dark: false)!.size) }
        save(Sheet(zoom: 1, caption: "곰돌이 숫자(% 없음)·간격 12pt — Retina 2배율 실제 픽셀"), scale: 2, to: "40-bear-digits-actual-2x.png")
        save(Sheet(zoom: 4, caption: "확대 — Retina 2배율 픽셀을 보간 없이 2배 (= 4배)"), scale: 2 / 2, to: "41-bear-digits-zoom4x.png")
    }
}
