// sheetf <board.png> <conceptsDir> <out.png> : D final-candidate comparison
// (reference · D1 · D3 · final candidate; large, light/dark true-pixel sizes, 32px zoom).
import AppKit

let a = CommandLine.arguments
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ p: String) -> CGImage { var r = CGRect.zero; return NSImage(contentsOfFile: p)!.cgImage(forProposedRect: &r, context: nil, hints: nil)! }
let board = load(a[1]), dir = a[2]

struct Col { let title: String; let sub: String; let folder: String? }
let cols = [Col(title: "레퍼런스 D", sub: "첨부 보드 원본 픽셀", folder: nil),
            Col(title: "기존 D1", sub: "D-refinement/D1", folder: "D-refinement/D1"),
            Col(title: "기존 D3", sub: "D-refinement/D3", folder: "D-refinement/D3"),
            Col(title: "최종 후보", sub: "D-final-candidate", folder: "D-final-candidate")]

let colW = 420, left = 150, W = left + colW * cols.count + 20
let rows: [(String, Int)] = [("크게 보기\n(배경판 316px)", 340), ("겹침 경계\n확대", 340), ("라이트 배경\n128·64·32·16px\n실제 픽셀", 190), ("다크 배경\n128·64·32·16px\n실제 픽셀", 190), ("32px ×4 확대\n(라이트 · 다크)", 160)]
let headerH = 170
let H = headerH + rows.reduce(0) { $0 + $1.1 + 20 } + 20
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor(srgbRed: 0.972, green: 0.972, blue: 0.984, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func text(_ s: String, _ x: Int, _ yTop: Int, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .black, width: CGFloat = 380) {
    let para = NSMutableParagraphStyle(); para.lineSpacing = 2
    let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para])
    let h = str.boundingRect(with: NSSize(width: width, height: 400), options: .usesLineFragmentOrigin).height
    str.draw(with: NSRect(x: CGFloat(x), y: CGFloat(H - yTop) - h, width: width, height: h), options: .usesLineFragmentOrigin)
}
func draw(_ img: CGImage, _ x: Int, _ yTop: Int, _ w: Int, _ h: Int, nearest: Bool = false) {
    ctx.interpolationQuality = nearest ? .none : .high
    ctx.draw(img, in: CGRect(x: x, y: H - yTop - h, width: w, height: h))
}
func panel(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int, dark: Bool) {
    ctx.setFillColor(dark ? NSColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1).cgColor : NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: H - yTop - h, width: w, height: h), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
}

text("Tokenly 앱 아이콘 — D 최종 후보 비교", 30, 24, 30, .bold, width: 1200)
text("레퍼런스는 첨부 보드의 원본 픽셀을 그대로 사용(업스케일 없음). 보드의 작은 아이콘은 실제 128/64/32/16px가 아니라 축소된 일러스트이므로 참고용입니다.\n렌더 결과는 모두 2048px 원본에서 축소했습니다. 32px 확대는 nearest-neighbor ×4.", 30, 68, 15, .regular, .darkGray, width: 2000)
for (i, c) in cols.enumerated() {
    let x = left + i * colW
    text(c.title, x, headerH - 44, 18, .semibold)
    text(c.sub, x, headerH - 20, 12, .regular, .gray)
}

var y = headerH
// Row 1: large
text(rows[0].0, 30, y + 120, 15, .medium, .darkGray, width: 115)
for (i, c) in cols.enumerated() {
    let x = left + i * colW
    if let f = c.folder {
        draw(load("\(dir)/\(f)/icon-1024.png").cropping(to: CGRect(x: 100, y: 100, width: 824, height: 824))!, x, y, 340, 340)
    } else {
        draw(board.cropping(to: CGRect(x: 1170, y: 122, width: 316, height: 316))!, x, y + 12, 316, 316)
    }
}
y += rows[0].1 + 20
// Row: overlap window (u −0.5…0.5, v −0.6…0.4), reference ×2.2 vs renders at native 1024 scale
text(rows[1].0, 30, y + 140, 15, .medium, .darkGray, width: 115)
for (i, c) in cols.enumerated() {
    let x = left + i * colW
    if let f = c.folder {
        draw(load("\(dir)/\(f)/icon-1024.png").cropping(to: CGRect(x: 306, y: 347, width: 412, height: 412))!, x, y, 340, 340)
    } else {
        draw(board.cropping(to: CGRect(x: 1250, y: 217, width: 157, height: 157))!, x, y, 340, 340)
    }
}
y += rows[1].1 + 20
// Rows 2–3: true pixel sizes on light / dark
for (ri, dark) in [false, true].enumerated() {
    text(rows[2 + ri].0, 30, y + 50, 15, .medium, .darkGray, width: 115)
    for (i, c) in cols.enumerated() {
        let x = left + i * colW
        panel(x, y, 370, rows[2 + ri].1, dark: dark)
        if let f = c.folder {
            var cx = x + 18
            for s in [128, 64, 32, 16] {
                draw(load("\(dir)/\(f)/icon-\(s).png"), cx, y + 30 + (128 - s) / 2, s, s, nearest: true)
                cx += s + 30
            }
        } else {
            // Board strips: light rows (512…16) or dark rows (128…16), native pixels, laid out horizontally.
            let strip = dark ? board.cropping(to: CGRect(x: 1258, y: 766, width: 124, height: 228))!
                             : board.cropping(to: CGRect(x: 1248, y: 452, width: 144, height: 284))!
            let h = rows[2 + ri].1 - 20, w = strip.width * h / strip.height
            draw(strip, x + 18, y + 10, w, h)
            text("보드의 크기 열\n(원본 그대로, 축소 일러스트)", x + 30 + w, y + 60, 12, .regular, dark ? .lightGray : .gray, width: 200)
        }
    }
    y += rows[2 + ri].1 + 20
}
// Row 4: 32px zoom
text(rows[4].0, 30, y + 50, 15, .medium, .darkGray, width: 115)
for (i, c) in cols.enumerated() {
    let x = left + i * colW
    panel(x, y, 182, 160, dark: false); panel(x + 188, y, 182, 160, dark: true)
    if let f = c.folder {
        let img = load("\(dir)/\(f)/icon-32.png")
        draw(img, x + 27, y + 16, 128, 128, nearest: true)
        draw(img, x + 188 + 27, y + 16, 128, 128, nearest: true)
    } else {
        // Board's "32px" icons are ~22px; shown ×4 for reference.
        draw(board.cropping(to: CGRect(x: 1309, y: 683, width: 22, height: 22))!, x + 47, y + 36, 88, 88, nearest: true)
        draw(board.cropping(to: CGRect(x: 1309, y: 929, width: 22, height: 22))!, x + 188 + 47, y + 36, 88, 88, nearest: true)
    }
}
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("sheet", W, H)
