// colorcheck <native-396> <icon...> : mean colour of regions (in plate units) in native vs each size.
import Foundation
let a = CommandLine.arguments
let native = Raw(a[1])
let regions: [(String, Double, Double)] = [("라벤더", 0.0, 0.45), ("블루", -0.6, -0.1), ("옐로우", 0.55, -0.2), ("라벤더+블루", -0.2, 0.15),
                                          ("라벤더+옐로우", 0.3, 0.05), ("블루+옐로우", 0.0, -0.4), ("세 개 겹침", 0.0, -0.15), ("배경판", -0.85, 0.85)]
func mean(_ r: Raw, _ u: Double, _ v: Double, _ rad: Double) -> (Double, Double, Double) {
    // plate centre = canvas centre; plate half-width = 159.5/396 of the canvas
    let S = Double(r.w), cx = S / 2 + u * 159.5 / 396 * S, cy = S / 2 - v * 155.5 / 396 * S, R = max(0.6, rad * S / 396)
    var s = (0.0, 0.0, 0.0), n = 0.0
    for y in Int(cy - R)...Int(cy + R) { for x in Int(cx - R)...Int(cx + R) where (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy) <= R * R {
        let p = r.px(x, y); s.0 += Double(p.0); s.1 += Double(p.1); s.2 += Double(p.2); n += 1 } }
    return (s.0 / n, s.1 / n, s.2 / n)
}
var header = "region".padding(toLength: 14, withPad: " ", startingAt: 0)
let icons = a.dropFirst(2).map { ($0.split(separator: "-").last!.split(separator: ".").first!, Raw($0)) }
for (n, _) in icons { header += "  \(n)".padding(toLength: 12, withPad: " ", startingAt: 0) }
print(header + "  (max |Δ| vs native, region radius 6 native px)")
for (name, u, v) in regions {
    let ref = mean(native, u, v, 6)
    var line = name.padding(toLength: 12, withPad: " ", startingAt: 0)
    for (_, r) in icons {
        if r.w < 64 { line += "  –".padding(toLength: 12, withPad: " ", startingAt: 0); continue }
        let m = mean(r, u, v, 6)
        let d = max(abs(m.0 - ref.0), abs(m.1 - ref.1), abs(m.2 - ref.2))
        line += String(format: "  %-10.1f", d)
    }
    print(line)
}
