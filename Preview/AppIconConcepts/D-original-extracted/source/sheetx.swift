// sheetx <dir D-original-extracted> <swiftCandidateDir> : writes comparison-sheet.png and dock-preview.png
import AppKit

let a = CommandLine.arguments
let dir = a[1], swiftDir = a[2]
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ p: String) -> CGImage { Raw(p).image }

final class Sheet {
    let W: Int, H: Int, ctx: CGContext
    init(_ w: Int, _ h: Int, bg: CGColor) {
        W = w; H = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    }
    func text(_ s: String, _ x: Int, _ yTop: Int, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .black, width: CGFloat = 1600) {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para])
        let h = str.boundingRect(with: NSSize(width: width, height: 2000), options: .usesLineFragmentOrigin).height
        str.draw(with: NSRect(x: CGFloat(x), y: CGFloat(H - yTop) - h, width: width, height: h), options: .usesLineFragmentOrigin)
    }
    func draw(_ img: CGImage, _ x: Int, _ yTop: Int, _ w: Int, _ h: Int, nearest: Bool = false) {
        ctx.interpolationQuality = nearest ? .none : .high
        ctx.draw(img, in: CGRect(x: x, y: H - yTop - h, width: w, height: h))
    }
    func rect(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int, _ c: CGColor, radius: CGFloat = 12) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: H - yTop - h, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
    }
    func save(_ path: String) { try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }
}
let light = CGColor(srgbRed: 0.972, green: 0.972, blue: 0.984, alpha: 1), white = CGColor(gray: 1, alpha: 1)
let dark = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.135, alpha: 1)

let crop = load("\(dir)/original-crop-343.png"), native = load("\(dir)/native-396.png")
let x1024 = load("\(dir)/icon-1024.png"), s1024 = load("\(swiftDir)/icon-1024.png")
let rs = "\(dir)/resampling-comparison"

// MARK: comparison sheet
let S = Sheet(1900, 2420, bg: light)
S.text("Tokenly 앱 아이콘 — 원본 D안 추출본 검증", 30, 24, 30, .bold)
S.text("원본: 콘셉트 보드 1536×1024px의 D안 (배경판 319×311px). 추출본 픽셀은 재생성·보정 없이 그대로이며, 1024·512px는 Lanczos 업스케일입니다(디테일이 늘어나지 않음).", 30, 68, 15, .regular, .darkGray)

// Row 1: original crop · extracted (native scale) · Swift candidate (same plate scale)
var y = 120
S.text("① 같은 배경판 크기 비교 (배경판 ≈ 319px)", 30, y, 19, .semibold); y += 36
let labels1 = ["원본 크롭 343×343 (보드 픽셀 그대로, 1:1)", "추출본 네이티브 396×396 (투명 배경, 1:1)", "기존 Swift 최종 후보 (1024 → 396 축소)"]
for (i, l) in labels1.enumerated() { S.text(l, 30 + i * 620, y, 14, .regular, .gray) }
y += 26
S.draw(crop, 30 + 26, y + 26, 343, 343)
S.rect(650, y, 420, 420, white); S.draw(native, 650 + 12, y + 12, 396, 396)
S.rect(1270, y, 420, 420, white); S.draw(s1024, 1270 + 12, y + 12, 396, 396)
y += 440

// Row 2: resampling comparison
S.text("② 1024px 업스케일 방법 비교 (보라 구체 하이라이트 부분, 1024px 기준 ×2 확대)", 30, y, 19, .semibold); y += 36
let methods = [("nearest", "최근접 — 계단 현상"), ("bilinear", "쌍선형 — 가장 흐림"), ("bicubic-catmullrom", "쌍입방 — 선명, 과도진동 0.82%"), ("lanczos", "Lanczos (채택) — 선명, 과도진동 0.80%")]
for (i, m) in methods.enumerated() {
    let img = load("\(rs)/1024-\(m.0).png").cropping(to: CGRect(x: 330, y: 250, width: 180, height: 180))!
    S.text(m.1, 30 + i * 460, y, 14, .regular, .gray)
    S.draw(img, 30 + i * 460, y + 24, 360, 360, nearest: true)
}
y += 410

// Row 3: 1024 1:1 detail, extracted vs Swift
S.text("③ 1024px 실제 픽셀 1:1 (중앙 겹침 부분 420×300) — 추출본은 업스케일이라 Swift 렌더보다 부드러움", 30, y, 19, .semibold); y += 36
S.text("추출본 icon-1024 (Lanczos ×2.59)", 30, y, 14, .regular, .gray); S.text("Swift 최종 후보 icon-1024 (2048 렌더에서 축소)", 960, y, 14, .regular, .gray)
S.draw(x1024.cropping(to: CGRect(x: 300, y: 330, width: 420, height: 300))!, 30, y + 24, 840, 600, nearest: true)
S.draw(s1024.cropping(to: CGRect(x: 300, y: 330, width: 420, height: 300))!, 960, y + 24, 840, 600, nearest: true)
y += 650

// Row 4: small sizes on light / dark
S.text("④ 실제 픽셀 크기 256·128·64·32·16px (라이트 · 다크) + 32px ×4", 30, y, 19, .semibold); y += 36
for (ri, (name, folder)) in [("추출본", dir), ("Swift 최종 후보", swiftDir)].enumerated() {
    let rowY = y + ri * 290
    S.text(name, 30, rowY + 120, 16, .medium, .darkGray, width: 140)
    for (pi, bgc) in [white, dark].enumerated() {
        let x0 = 180 + pi * 760
        S.rect(x0, rowY, 740, 280, bgc)
        var cx = x0 + 14
        for s in [256, 128, 64, 32, 16] where FileManager.default.fileExists(atPath: "\(folder)/icon-\(s).png") {
            S.draw(load("\(folder)/icon-\(s).png"), cx, rowY + 12 + (256 - s) / 2, s, s, nearest: true); cx += s + 18
        }
        let z = load("\(folder)/icon-32.png")
        S.draw(z, x0 + 740 - 14 - 128, rowY + 140, 128, 128, nearest: true)
    }
}
S.save("\(dir)/comparison-sheet.png")

// MARK: Dock preview
let D = Sheet(1900, 760, bg: light)
D.text("Dock 크기 미리보기 — 추출본 · Swift 최종 후보 (회색 사각형은 크기 비교용 일반 자리표시)", 30, 24, 24, .bold)
D.text("Retina 기준: 48pt = 96px, 64pt = 128px, 확대 128pt = 256px. 96px는 icon-128을 고품질로 축소해 표시했습니다.", 30, 60, 14, .regular, .darkGray)
func placeholder(_ px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = CGFloat(px) * 0.098, side = CGFloat(px) - 2 * inset
    c.setFillColor(CGColor(gray: 0.72, alpha: 1))
    c.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)); c.fillPath()
    return c.makeImage()!
}
let xi128 = load("\(dir)/icon-128.png"), si128 = load("\(swiftDir)/icon-128.png")
let xi256 = load("\(dir)/icon-256.png"), si256 = load("\(swiftDir)/icon-1024.png")
for (bi, (dockC, name)) in [(CGColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1), "라이트 Dock"), (CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1), "다크 Dock")].enumerated() {
    let top = 100 + bi * 330
    D.rect(20, top - 10, 1860, 320, bi == 0 ? CGColor(srgbRed: 0.80, green: 0.84, blue: 0.92, alpha: 1) : CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1), radius: 16)
    D.text(name, 40, top, 15, .semibold, bi == 0 ? .black : .white)
    // 64pt dock (128 px)
    D.rect(40, top + 40, 760, 150, dockC, radius: 26)
    let row64: [CGImage] = [placeholder(128), xi128, placeholder(128), si128, placeholder(128)]
    for (i, img) in row64.enumerated() { D.draw(img, 52 + i * 148, top + 51, 128, 128) }
    D.text("64pt (128px): 자리표시 · 추출본 · 자리표시 · Swift 후보 · 자리표시", 40, top + 200, 12, .regular, bi == 0 ? .darkGray : .lightGray, width: 760)
    // 48pt dock (96 px)
    D.rect(830, top + 56, 600, 118, dockC, radius: 22)
    let row48: [CGImage] = [placeholder(96), xi128, placeholder(96), si128, placeholder(96)]
    for (i, img) in row48.enumerated() { D.draw(img, 842 + i * 114, top + 67, 96, 96) }
    D.text("48pt (96px)", 830, top + 200, 12, .regular, bi == 0 ? .darkGray : .lightGray)
    // magnified 128pt (256 px): extracted and Swift
    D.draw(xi256, 1450, top + 20, 200, 200); D.draw(si256, 1660, top + 20, 200, 200)
    D.text("확대 상태 (256px를 200px로 표시): 추출본 · Swift 후보", 1450, top + 230, 12, .regular, bi == 0 ? .darkGray : .lightGray, width: 420)
}
D.save("\(dir)/dock-preview.png")
print("sheets written")
