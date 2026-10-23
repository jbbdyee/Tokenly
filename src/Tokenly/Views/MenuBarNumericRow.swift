import AppKit
import SwiftUI

// Numeric menu bar style: per service, the 5-hour remaining large and high, a small "/", the 7-day
// remaining smaller and slightly lower, and the service name centred underneath. Text only, in the
// menu bar's black or white; stale services are dimmed.

enum MenuBarNumericImage {
    struct Layout: Equatable {
        /// 5-hour digits.
        var primarySize: CGFloat = 12
        /// 7-day digits relative to the 5-hour size (0.8 = 20% smaller).
        var secondaryRatio: CGFloat = 0.8
        /// How much lower the 7-day baseline sits than the 5-hour one.
        var drop: CGFloat = 1.5
        /// "/" size relative to the 7-day digits.
        var separatorRatio: CGFloat = 0.85
        /// Ink gap on each side of "/".
        var separatorGap: CGFloat = 0.7
        var nameSize: CGFloat = 6
        /// Clear space between the lowest digit ink and the name's cap top.
        var digitsToName: CGFloat = 1.75
        var primaryWeight: NSFont.Weight = .heavy
        var secondaryWeight: NSFont.Weight = .heavy
        var separatorWeight: NSFont.Weight = .semibold
        var nameWeight: NSFont.Weight = .heavy
        /// Space between service columns (numeric style only; bear/heart use MenuBarGaugeRow.spacing).
        var columnSpacing: CGFloat = 12

        /// The first numeric design (heavy, 0.7pt gaps, 1.5pt drop), kept for comparison.
        static let first = Layout()
        /// Chosen in Preview/Numeric/72 next to the menu bar's own text: lighter weights (5h Semibold,
        /// 7d and "/" Medium; names Semibold so 6pt stays legible), 1.2pt around "/", 2pt drop, and 16pt
        /// between services (the user's "more space" meant between Codex/Claude/AGY, not around "/").
        static let standard = Layout(drop: 2.0, separatorGap: 1.2, primaryWeight: .semibold,
                                     secondaryWeight: .medium, separatorWeight: .medium, nameWeight: .semibold,
                                     columnSpacing: 16)
    }

    static let height: CGFloat = 22
    static let sidePadding: CGFloat = 1
    static let staleAlpha: CGFloat = 0.5

    static func font(_ size: CGFloat, weight: NSFont.Weight = .heavy) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
    }

    static func line(_ text: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]) as CFAttributedString)
    }

    static func ink(_ line: CTLine) -> CGRect { CTLineGetBoundsWithOptions(line, .useGlyphPathBounds) }

    /// A drawn run of text: line plus its baseline origin, in top-left point coordinates.
    struct Run { let line: CTLine; let x: CGFloat; let baseline: CGFloat }

    /// Lays out one column. Returns its width and the runs positioned from x = 0, using the digits'
    /// ink boxes so "100/100" and "0/0" sit as tightly and evenly as "40/70".
    static func column(_ item: NumericGaugeItem, layout: Layout, color: CGColor) -> (width: CGFloat, runs: [Run]) {
        let digitColor = item.stale ? color.copy(alpha: staleAlpha)! : color
        let primary = line(NumericGaugeItem.text(item.primary), font(layout.primarySize, weight: layout.primaryWeight), digitColor)
        let p = ink(primary)
        let nameLine = line(item.name, font(layout.nameSize, weight: layout.nameWeight), color)
        let n = ink(nameLine)
        var digitRuns: [(CTLine, CGRect, CGFloat)] = [(primary, p, 0)]   // line, ink, baseline drop
        if item.hasSecondarySlot {
            let secondarySize = layout.primarySize * layout.secondaryRatio
            let slash = line("/", font(secondarySize * layout.separatorRatio, weight: layout.separatorWeight),
                             digitColor.copy(alpha: digitColor.alpha * 0.7)!)
            let secondary = line(NumericGaugeItem.text(item.secondary), font(secondarySize, weight: layout.secondaryWeight), digitColor)
            // "/" dips below its baseline; centre its ink on the band from the 5h top to the 7d baseline
            // instead, so it never becomes the lowest ink (that had cut the digits-to-name gap to ~1.3pt).
            let slashInk = ink(slash)
            let digitTop = ink(line("0", font(layout.primarySize, weight: layout.primaryWeight), .black)).maxY
            let slashDrop = (layout.drop - digitTop) / 2 + slashInk.midY
            digitRuns.append((slash, slashInk, slashDrop))
            digitRuns.append((secondary, ink(secondary), layout.drop))
        }
        // Horizontal: ink boxes laid side by side with the separator gaps.
        var x: CGFloat = 0
        var placed: [(CTLine, CGFloat, CGRect, CGFloat)] = []   // line, ink-left x, ink, drop
        for (index, run) in digitRuns.enumerated() {
            if index > 0 { x += layout.separatorGap }
            placed.append((run.0, x, run.1, run.2))
            x += run.1.width
        }
        let digitsWidth = x
        let width = max(digitsWidth, n.width)
        // Vertical: fixed from font metrics, not from each value's ink, so every column (two numbers or
        // AGY's one) shares the same 5h baseline and the names line up across the row.
        let v = vertical(layout)
        var runs = placed.map { run -> Run in
            let baseline = item.hasSecondarySlot ? v.primaryBaseline + run.3 : v.singleBaseline
            return Run(line: run.0, x: (width - digitsWidth) / 2 + run.1 - run.2.minX, baseline: baseline)
        }
        runs.append(Run(line: nameLine, x: (width - n.width) / 2 - n.minX, baseline: v.nameBaseline))
        return (width, runs)
    }

    /// Baselines (points from the top) for a layout: 5h cap top → 7d baseline (5h baseline + drop),
    /// a gap, then the name's cap height, the whole block centred in the 22pt row.
    static func vertical(_ layout: Layout) -> (primaryBaseline: CGFloat, singleBaseline: CGFloat, nameBaseline: CGFloat) {
        // Measured glyph extents, not cap height: round digits overshoot the baseline and the names'
        // "d"/"l" rise above the cap height (using cap height left only ~1pt between digits and name).
        let digitTop = ink(line("0", font(layout.primarySize, weight: layout.primaryWeight), .black)).maxY
        let digitOvershoot = max(0, -ink(line("0", font(layout.primarySize * layout.secondaryRatio,
                                                         weight: layout.secondaryWeight), .black)).minY)
        let nameTop = ink(line("Cdl", font(layout.nameSize, weight: layout.nameWeight), .black)).maxY
        let block = digitTop + layout.drop + digitOvershoot + layout.digitsToName + nameTop
        let top = (height - block) / 2
        let primaryBaseline = top + digitTop
        let nameBaseline = primaryBaseline + layout.drop + digitOvershoot + layout.digitsToName + nameTop
        // A lone number (AGY) is centred in the same digits band.
        return (primaryBaseline, primaryBaseline + layout.drop / 2, nameBaseline)
    }

    static func size(_ items: [NumericGaugeItem], layout: Layout = .standard) -> CGSize {
        let widths = items.map { column($0, layout: layout, color: .black).width }
        let total = 2 * sidePadding + widths.reduce(0, +) + CGFloat(max(0, items.count - 1)) * layout.columnSpacing
        return CGSize(width: total.rounded(.up), height: height)
    }

    static func render(_ items: [NumericGaugeItem], dark: Bool, scale: Int, layout: Layout = .standard) -> CGImage? {
        guard !items.isEmpty else { return nil }
        let color = dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let columns = items.map { column($0, layout: layout, color: color) }
        let size = size(items, layout: layout)
        guard let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setShouldSmoothFonts(false)
        func snap(_ v: CGFloat) -> CGFloat { (v * CGFloat(scale)).rounded() / CGFloat(scale) }
        var x = sidePadding
        for column in columns {
            for run in column.runs {
                ctx.textPosition = CGPoint(x: snap(x + run.x), y: snap(height - run.baseline))
                CTLineDraw(run.line, ctx)
            }
            x += column.width + layout.columnSpacing
        }
        return ctx.makeImage()
    }

    @MainActor
    static func make(_ items: [NumericGaugeItem], dark: Bool, layout: Layout = .standard) -> NSImage? {
        let scale = max(2, Int((NSScreen.main?.backingScaleFactor ?? 2).rounded()))
        guard let image = render(items, dark: dark, scale: scale, layout: layout) else { return nil }
        let result = NSImage(cgImage: image, size: size(items, layout: layout))
        result.isTemplate = false
        return result
    }
}
