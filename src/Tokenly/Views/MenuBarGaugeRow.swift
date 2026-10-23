import AppKit
import SwiftUI

// Menu bar row renderer for the bear style: each icon's body (already filled to its level)
// with digits centred on it, then the service name set horizontally into its lower outline.
// The name never bends: the body and outline are cleared just around the glyphs so the name
// interrupts the outline instead of floating on the jelly.

/// One icon in a row. Coordinates are points in the icon's column, origin top-left.
struct GaugeIcon {
    /// Pixels at the row scale; may be larger than the column (padding for rims and shadows).
    let body: CGImage
    let bodyFrame: CGRect
    /// Visual centre for the digits' glyph ink box.
    let numberCenter: CGPoint
    /// y of the name's glyph ink centre: the bottom edge of the silhouette.
    let nameCenterY: CGFloat
    let text: String
    let digitSize: CGFloat
    let style: GaugeDigits.Style
    let name: String
    /// Bear tone for the strong outline (codex, claude, antigravity, stale).
    let outlineTone: String
}

/// Digits only ("89", never "89%"), positioned by their glyph ink box rather than the text layout box.
enum GaugeDigits {
    struct Style { let fill: CGColor; let outline: CGColor }
    static let outlineWidth: CGFloat = 0.35

    static func text(_ percent: Double?) -> String {
        percent.map { "\(Int(min(max($0, 0), 100).rounded()))" } ?? "?"
    }

    static func font(_ size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
    }

    static func line(_ text: String, size: CGFloat, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font(size), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]) as CFAttributedString)
    }

    static func inkBounds(_ text: String, size: CGFloat) -> CGRect {
        CTLineGetBoundsWithOptions(line(text, size: size, color: .black), .useGlyphPathBounds)
    }
}

enum MenuBarGaugeRow {
    static let height: CGFloat = 22
    /// Space between bears.
    static let spacing: CGFloat = 12
    static let sidePadding: CGFloat = 1
    static let nameFontSize: CGFloat = 6
    /// Cap height of the 6pt heavy rounded name, halved.
    static let nameHalfHeight: CGFloat = 4.38 / 2
    /// Body and outline are cleared this far around the name glyphs.
    static let nameKnockout: CGFloat = 0.75

    @MainActor
    static var scale: Int { max(2, Int((NSScreen.main?.backingScaleFactor ?? 2).rounded())) }

    static func snap(_ value: CGFloat, scale: Int) -> CGFloat { (value * CGFloat(scale)).rounded() / CGFloat(scale) }

    /// Whole points so the status item never resamples the bitmap.
    static func size(count: Int, columnWidth: CGFloat) -> CGSize {
        let n = CGFloat(max(count, 1))
        return CGSize(width: (2 * sidePadding + n * columnWidth + (n - 1) * spacing).rounded(.up), height: height)
    }

    static func columnX(_ index: Int, columnWidth: CGFloat) -> CGFloat {
        sidePadding + CGFloat(index) * (columnWidth + spacing)
    }

    static func render(_ icons: [GaugeIcon], columnWidth: CGFloat, scale: Int, dark: Bool,
                       strongOutline: Bool) -> CGImage? {
        let size = size(count: icons.count, columnWidth: columnWidth)
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        func context() -> CGContext? {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx?.setShouldSmoothFonts(false)
            return ctx
        }
        // Core Graphics is y-up; icon coordinates are top-left.
        func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }

        guard let bodies = context() else { return nil }
        bodies.interpolationQuality = .none
        var names: [(CTLine, CGPoint)] = []
        let nameColor = dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        for (index, icon) in icons.enumerated() {
            let x0 = columnX(index, columnWidth: columnWidth)
            bodies.draw(icon.body, in: flip(icon.bodyFrame.offsetBy(dx: x0, dy: 0)))
            // Digits: ink box centred on the face/heart. The ink box's left and bottom edges (not the
            // baseline origin) are snapped to the pixel grid: crisper strokes, centre within ¼pt.
            let ink = GaugeDigits.inkBounds(icon.text, size: icon.digitSize)
            let inkLeft = snap(x0 + icon.numberCenter.x - ink.width / 2, scale: scale)
            let inkBottom = snap(size.height - icon.numberCenter.y - ink.height / 2, scale: scale)
            let origin = CGPoint(x: inkLeft - ink.minX, y: inkBottom - ink.minY)
            let outline = GaugeDigits.line(icon.text, size: icon.digitSize, color: icon.style.outline)
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                bodies.textPosition = CGPoint(x: origin.x + CGFloat(cos(angle)) * GaugeDigits.outlineWidth,
                                              y: origin.y + CGFloat(sin(angle)) * GaugeDigits.outlineWidth)
                CTLineDraw(outline, bodies)
            }
            bodies.textPosition = origin
            CTLineDraw(GaugeDigits.line(icon.text, size: icon.digitSize, color: icon.style.fill), bodies)
            // Name: horizontal, centred under the icon, glyph centre on the silhouette's bottom edge.
            let nameLine = GaugeDigits.line(icon.name, size: nameFontSize, color: nameColor)
            let nameInk = CTLineGetBoundsWithOptions(nameLine, .useGlyphPathBounds)
            names.append((nameLine, CGPoint(x: snap(x0 + columnWidth / 2 - nameInk.midX, scale: scale),
                                            y: snap(size.height - icon.nameCenterY - nameInk.midY, scale: scale))))
        }
        guard var image = bodies.makeImage() else { return nil }
        if strongOutline {
            image = BearOutline.apply(to: image, scale: scale, services: icons.map(\.outlineTone))
        }

        // Clear the body and outline within `nameKnockout` of the name glyphs, then draw the names.
        guard let mask = context() else { return nil }
        for (line, origin) in names { mask.textPosition = origin; CTLineDraw(line, mask) }
        guard let maskImage = mask.makeImage(), let cleared = knockout(image, mask: maskImage, radius: nameKnockout * CGFloat(scale)),
              let final = context() else { return nil }
        final.draw(cleared, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        for (line, origin) in names { final.textPosition = origin; CTLineDraw(line, final) }
        return final.makeImage()
    }

    /// Multiplies `image` by (1 − dilated mask alpha), the dilation being a soft disc of `radius` pixels.
    static func knockout(_ image: CGImage, mask: CGImage, radius: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        func bytes(_ source: CGImage) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return b
        }
        var px = bytes(image)
        let m = bytes(mask)
        let reach = Int(radius.rounded(.up))
        for y in 0..<h {
            for x in 0..<w {
                var k: CGFloat = 0
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let a = CGFloat(m[(yy * w + xx) * 4 + 3]) / 255
                        guard a > 0 else { continue }
                        let distance = CGFloat(dx * dx + dy * dy).squareRoot()
                        k = max(k, a * min(1, max(0, radius + 0.5 - distance)))
                    }
                }
                if k > 0 {
                    let i = (y * w + x) * 4
                    for c in 0..<4 { px[i + c] = UInt8((CGFloat(px[i + c]) * (1 - k)).rounded()) }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
