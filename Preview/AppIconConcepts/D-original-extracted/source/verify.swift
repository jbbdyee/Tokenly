// verify: crop must equal the board region byte-for-byte; native canvas must equal the board wherever alpha = 255.
let b = Raw(CommandLine.arguments[1]), c = Raw(CommandLine.arguments[2]), n = Raw(CommandLine.arguments[3])
var diff = 0, maxd = 0
for y in 0..<343 { for x in 0..<343 {
    let p = b.px(1156 + x, 104 + y), q = c.px(x, y)
    let d = max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)); if d > 0 { diff += 1 }; maxd = max(maxd, d)
} }
print("crop vs board: \(343 * 343) px, differing \(diff), max Δ \(maxd)")
var opaque = 0, odiff = 0, omax = 0, partial = 0, shadow = 0
for y in 0..<396 { for x in 0..<396 {
    let o = y * n.bpr + x * n.bpp; let a = Int(n.data[o + 3])
    if a == 255 {
        opaque += 1
        let p = b.px(1129 + x, 77 + y), q = n.px(x, y)
        let d = max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)); if d > 0 { odiff += 1 }; omax = max(omax, d)
    } else if a > 0 { if a > 200 { partial += 1 } else { shadow += 1 } }
} }
print("native canvas: opaque \(opaque) px (differing from board \(odiff), max Δ \(omax)); edge AA \(partial) px; shadow/soft \(shadow) px")
