import AppKit

/// Menu bar images for the system widgets, in the AI numeric style (Doc/SYSTEM-MONITOR.md §7.1, §7.3).
///
/// Fonts, sizes, weights, baselines, ink alignment, pixel snapping, colours and height all come from
/// `MenuBarNumericImage` and its `Layout.standard`; that file is not changed. Only the column composition and the
/// side padding are system-specific, because `MenuBarNumericImage.column` takes AI service items:
/// - CPU·RAM·Disk·GPU: the AGY single-number column with a `%` (`percentRatio` size, secondary weight, same baseline). The
///   column is as wide as the widest two-digit value, so a 1 s update between 0 % and 99 % never resizes the
///   item; only `100%` is wider (the AI columns follow their numbers too).
/// - Battery: one row, `82%` or `⚡82%` (Doc/SYSTEM-MONITOR.md §7.1 bolt policy). No battery outline in any state.
///   The digits and the bolt are centred in the 22 pt image's full height (it is one row, so it is not matched
///   to the two-row widgets' digit row). The bolt takes room only while shown.
///
/// The space between two menu bar items is mostly macOS's own status item padding (8 pt each side, not
/// adjustable by an app without changing a system-wide setting). The app only controls the image: a 0.5 pt side
/// padding (`itemPadding`) and the column width above.
enum MenuBarSystemImage {
    static let layout = MenuBarNumericImage.Layout.standard
    /// `%` size relative to the digits. The AI uses `layout.secondaryRatio` (0.8) for its secondary numbers and keeps
    /// it; the system `%` is a little smaller so the number reads first. Same weight and baseline as before.
    static let percentRatio: CGFloat = 0.75
    /// Ink gap between the number and its `%`, for CPU·RAM·Disk·GPU and Battery. Its own value, not the AI's
    /// `layout.separatorGap` (1.2 pt around "/"), which it equalled until 2026-10-28: at 2× that left one clear
    /// pixel in `24%`/`82%`. 1.7 pt gives two to three and no image grows (whole-point rounding absorbs it).
    static let percentGap: CGFloat = 1.7
    /// Side padding of a system widget image, half the AI's `MenuBarNumericImage.sidePadding`: these items stand
    /// alone, so the macOS item padding already separates them, while the AI image needs its own edge.
    static let itemPadding: CGFloat = 0.5

    /// The same black or white as `MenuBarNumericImage.render`.
    static func textColor(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }

    // MARK: Two-row widgets (CPU, RAM, Disk, GPU)

    /// Baselines of a two-row column, in points from the image top.
    struct RowBaselines: Equatable {
        let digits: CGFloat
        let name: CGFloat
    }

    /// Ink of a capital letter of the name font above its baseline (`H`, no overshoot).
    static let nameCapInk: CGRect = MenuBarNumericImage.ink(MenuBarNumericImage.line(
        "H", MenuBarNumericImage.font(layout.nameSize, weight: layout.nameWeight), textColor(dark: false)))

    /// Where the digits and the name sit for each display style.
    /// - `unified`: the AGY column's baselines, unchanged.
    /// - `split` (name above, number below): the `unified` box (digit cap top 3.60 pt to name baseline 19.40 pt)
    ///   mirrored, with the same clear space between the rows (the name's cap top takes the digits' cap top, the
    ///   digits' baseline takes the name's baseline), then raised as one block by `splitLift`.
    static func baselines(_ style: SystemWidgetLayout) -> RowBaselines {
        let v = MenuBarNumericImage.vertical(layout)
        switch style {
        case .unified:
            return RowBaselines(digits: v.singleBaseline, name: v.nameBaseline)
        case .split:
            let top = v.singleBaseline - digitInk.maxY - splitLift
            return RowBaselines(digits: v.nameBaseline - splitLift, name: top + nameCapInk.maxY)
        }
    }

    /// How far the split block sits above the mirrored box. With the large number in the lower row the block's
    /// visual weight fell 1.6–1.9 pt below the AI widgets'. First 1 pt (choice "C"), then 1 pt more after
    /// comparing with AGY's raised number and the framed Battery (2026-10-28): the weight is now within
    /// 0.1 pt of the AI widgets' (Doc/SYSTEM-MONITOR.md §7.3).
    static let splitLift: CGFloat = 2


    /// One two-row column: digits (and an optional `%`) above a name.
    struct Column: Equatable {
        let digits: String
        let suffix: String?
        let name: String
        let dimmed: Bool
    }

    static func column(_ display: SystemWidgetDisplay) -> Column {
        let digits: String
        if case .percent(let value) = display.value { digits = "\(value)" } else { digits = "—" }
        return Column(digits: digits, suffix: display.value.isPercent ? "%" : nil, name: display.widget.title,
                      dimmed: display.isDimmed)
    }

    private static func digitLines(_ digits: String, _ suffix: String?, color: CGColor) -> [CTLine] {
        let numberFont = MenuBarNumericImage.font(layout.primarySize, weight: layout.primaryWeight)
        var lines = [MenuBarNumericImage.line(digits, numberFont, color)]
        if let suffix {
            let suffixFont = MenuBarNumericImage.font(layout.primarySize * percentRatio, weight: layout.secondaryWeight)
            lines.append(MenuBarNumericImage.line(suffix, suffixFont, color))
        }
        return lines
    }

    /// Ink width of digits plus suffix laid side by side with the AI separator gap.
    private static func digitsWidth(_ lines: [CTLine]) -> CGFloat {
        let inks: CGFloat = lines.map { MenuBarNumericImage.ink($0).width }.reduce(0, +)
        let gaps = CGFloat(max(0, lines.count - 1)) * percentGap
        return inks + gaps
    }

    /// Ink width of the widest two-digit value with its `%` (10 % to 99 %); covers one digit and `—` too.
    static let twoDigitWidth: CGFloat = {
        let black = textColor(dark: false)
        return (10...99).map { digitsWidth(digitLines("\($0)", "%", color: black)) }.max() ?? 0
    }()

    /// Ink width of `100%`.
    static let hundredWidth: CGFloat = digitsWidth(digitLines("100", "%", color: textColor(dark: false)))

    /// Width the number part needs for `value`: the two-digit width, or `100%` at 100.
    static func digitSlotWidth(_ value: SystemWidgetDisplay.Value) -> CGFloat {
        value == .percent(100) ? hundredWidth : twoDigitWidth
    }

    /// Inner column width for a widget name and value: the wider of the digit slot and the name.
    static func fixedWidth(name: String, value: SystemWidgetDisplay.Value = .percent(0)) -> CGFloat {
        let black = textColor(dark: false)
        let nameLine = MenuBarNumericImage.line(name, MenuBarNumericImage.font(layout.nameSize, weight: layout.nameWeight), black)
        return max(digitSlotWidth(value), MenuBarNumericImage.ink(nameLine).width)
    }

    /// Lays out a column the way `MenuBarNumericImage.column` lays out AGY: ink boxes side by side, centred in the
    /// column, on the single-number baseline, with the name centred on the name baseline. `width == nil` uses the
    /// natural width (as AGY does); widgets pass `fixedWidth(name:)`.
    static func runs(_ column: Column, width: CGFloat?, dark: Bool,
                     style: SystemWidgetLayout = .unified) -> (width: CGFloat, runs: [MenuBarNumericImage.Run]) {
        let color = textColor(dark: dark)
        let digitColor = column.dimmed ? color.copy(alpha: MenuBarNumericImage.staleAlpha)! : color
        let lines = digitLines(column.digits, column.suffix, color: digitColor)
        let nameLine = MenuBarNumericImage.line(column.name, MenuBarNumericImage.font(layout.nameSize, weight: layout.nameWeight), color)
        let nameInk = MenuBarNumericImage.ink(nameLine)
        let inner = digitsWidth(lines)
        let columnWidth = width ?? max(inner, nameInk.width)
        let rows = baselines(style)

        var runs: [MenuBarNumericImage.Run] = []
        var x: CGFloat = 0
        for (index, line) in lines.enumerated() {
            if index > 0 { x += percentGap }
            let ink = MenuBarNumericImage.ink(line)
            runs.append(.init(line: line, x: (columnWidth - inner) / 2 + x - ink.minX, baseline: rows.digits))
            x += ink.width
        }
        runs.append(.init(line: nameLine, x: (columnWidth - nameInk.width) / 2 - nameInk.minX, baseline: rows.name))
        return (columnWidth, runs)
    }

    /// Image size for a column of `width`, rounded up as `MenuBarNumericImage.size` does.
    static func size(width: CGFloat, padding: CGFloat = itemPadding) -> CGSize {
        CGSize(width: (2 * padding + width).rounded(.up), height: MenuBarNumericImage.height)
    }

    /// Left edge of a `width` column in an image of `size(width:)`: the padding plus half of what rounding the
    /// image up to whole points added, so a column that fills its width (`100%`) keeps clear of both edges.
    static func left(width: CGFloat) -> CGFloat {
        itemPadding + (size(width: width).width - 2 * itemPadding - width) / 2
    }

    /// Widgets use `itemPadding` with the rounding split across both sides (`left(width:)`). The AGY comparison
    /// test passes `aiPadding: true`: the AI's own padding with the column at its left edge, as the AI draws it.
    static func render(_ column: Column, width: CGFloat?, dark: Bool, scale: Int, aiPadding: Bool = false,
                       style: SystemWidgetLayout = .unified) -> CGImage? {
        let laidOut = runs(column, width: width, dark: dark, style: style)
        let padding = aiPadding ? MenuBarNumericImage.sidePadding : itemPadding
        let origin = aiPadding ? padding : left(width: laidOut.width)
        return draw(size: size(width: laidOut.width, padding: padding), scale: scale) { ctx, snap in
            for run in laidOut.runs {
                ctx.textPosition = CGPoint(x: snap(origin + run.x),
                                           y: snap(MenuBarNumericImage.height - run.baseline))
                CTLineDraw(run.line, ctx)
            }
        }
    }

    // MARK: Battery (one row)

    static let boltSymbolName = "bolt.fill"

    /// Battery placement and bolt look. One value in the app (`standard`); tests and the before/after comparison
    /// render other values through the same code.
    struct BatteryStyle: Equatable {
        /// Digit baseline, in points from the top of the 22 pt image.
        var baseline: CGFloat
        /// Height of the bolt's ink (aspect kept).
        var boltHeight: CGFloat
        /// Symbol weight of `bolt.fill`; heavier is a fuller shape at the same height.
        var boltWeight: NSFont.Weight
        /// Clear space between the bolt's ink and the number's ink.
        var boltGap: CGFloat
        /// Raises the bolt's centre above the digits' cap-height centre (points, up is positive).
        var boltLift: CGFloat

        /// 6-2 / first 6-3 look: digits on the two-row widgets' baseline, 10 pt Medium bolt, 1 pt gap.
        static let previous = BatteryStyle(baseline: MenuBarNumericImage.vertical(layout).singleBaseline, boltHeight: 10,
                                           boltWeight: .medium, boltGap: 1, boltLift: 0)
        /// Final 6-3 look (Doc/SYSTEM-MONITOR.md §7.3): digits centred in the 22 pt image, a larger Bold bolt.
        static let standard = BatteryStyle(baseline: centredBaseline, boltHeight: 11.5, boltWeight: .bold,
                                           boltGap: 1.25, boltLift: 0)
    }

    /// Ink of the digits relative to their baseline (`0`: cap height plus the round overshoot at both ends).
    static let digitInk: CGRect = MenuBarNumericImage.ink(MenuBarNumericImage.line(
        "0", MenuBarNumericImage.font(layout.primarySize, weight: layout.primaryWeight), textColor(dark: false)))

    /// Baseline that puts the digits' ink centre on the 22 pt image's centre. Battery is a one-row item, so it is
    /// centred in the item's full height rather than matched to the two-row widgets' digit row (user decision).
    static let centredBaseline: CGFloat = MenuBarNumericImage.height / 2 + digitInk.midY

    /// Bolt green per appearance. On a light menu bar the system green (0.20/0.78/0.35) has little contrast with
    /// light wallpapers, so light mode uses a deeper green; dark mode keeps the brighter one.
    static func boltColor(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 0.24, green: 0.84, blue: 0.40, alpha: 1)
             : CGColor(srgbRed: 0.09, green: 0.62, blue: 0.24, alpha: 1)
    }

    private static func bolt(weight: NSFont.Weight, dark: Bool, alpha: CGFloat) -> NSImage? {
        let colour = NSColor(cgColor: boltColor(dark: dark).copy(alpha: alpha)!) ?? .systemGreen
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        return NSImage(systemSymbolName: boltSymbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// The bolt's ink inside its symbol image, in image points. Symbols carry padding (`bolt.fill` at 13 pt is
    /// 13 × 18 pt with ink at x 1.75–11.25, y 1.5–16.75, and its `alignmentRect` does not match the ink), so the
    /// padding would widen the gap to the number. Measured by drawing the symbol at 4×.
    static func boltInk(weight: NSFont.Weight) -> CGRect? {
        guard let symbol = bolt(weight: weight, dark: false, alpha: 1) else { return nil }
        let scale = 4
        let width = Int(symbol.size.width) * scale, height = Int(symbol.size.height) * scale
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        // Bitmap rows run top-down; image points run bottom-up.
        let s = CGFloat(scale)
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(height - 1 - maxY) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    /// Ink of the app's bolt, measured once.
    static let boltInk: CGRect? = boltInk(weight: BatteryStyle.standard.boltWeight)

    /// The bolt's drawn size: its ink scaled to the style's height.
    static func boltSize(_ style: BatteryStyle = .standard) -> CGSize {
        let ink = style == .standard ? boltInk : boltInk(weight: style.boltWeight)
        guard let ink, ink.height > 0 else { return CGSize(width: 6, height: style.boltHeight) }
        return CGSize(width: ink.width * style.boltHeight / ink.height, height: style.boltHeight)
    }

    /// Battery width: the bolt and its gap while shown, then the digit slot. Changes only when the bolt appears
    /// or disappears (a power event) or at 100 %, never between two readings of 0 % to 99 %.
    static func batteryWidth(_ display: SystemWidgetDisplay, style: BatteryStyle = .standard) -> CGFloat {
        (display.showsBolt ? boltSize(style).width + style.boltGap : 0) + digitSlotWidth(display.value)
    }


    static func renderBattery(_ display: SystemWidgetDisplay, dark: Bool, scale: Int,
                              style: BatteryStyle = .standard) -> CGImage? {
        let color = textColor(dark: dark)
        let alpha = display.isDimmed ? MenuBarNumericImage.staleAlpha : 1
        let digits: String
        if case .percent(let value) = display.value { digits = "\(value)" } else { digits = "—" }
        let lines = digitLines(digits, display.value.isPercent ? "%" : nil, color: color.copy(alpha: alpha)!)
        let boltImage = display.showsBolt ? bolt(weight: style.boltWeight, dark: dark, alpha: alpha) : nil
        if display.showsBolt && boltImage == nil { return nil }
        let ink = style == .standard ? boltInk : boltInk(weight: style.boltWeight)

        let width = batteryWidth(display, style: style)
        let height = MenuBarNumericImage.height
        // One row without a name: the digits keep the two-row widgets' size, and their ink centre and the bolt's
        // centre share one line, which for `standard` is the image's vertical centre. The `%` is smaller but on
        // the same baseline, so it does not move the group.
        let baseline = style.baseline
        let boltCentre = baseline - digitInk.midY - style.boltLift
        let bolt = boltSize(style)
        let inner = digitsWidth(lines)
        let content = (boltImage == nil ? 0 : bolt.width + style.boltGap) + inner
        let left = left(width: width) + (width - content) / 2

        return draw(size: size(width: width), scale: scale) { ctx, snap in
            var x = left + (boltImage == nil ? 0 : bolt.width + style.boltGap)
            if let boltImage, let first = lines.first {
                // Placed from where the number's ink actually lands after snapping, so the clear gap is the same
                // for every number (snapping the bolt and the digits separately varied it by up to 2 px).
                let numberLeft = snap(x - MenuBarNumericImage.ink(first).minX) + MenuBarNumericImage.ink(first).minX
                let rect = CGRect(x: numberLeft - style.boltGap - bolt.width, y: snap(height - boltCentre - bolt.height / 2),
                                  width: bolt.width, height: bolt.height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                // Only the ink part of the symbol, so the gap to the number is exactly `boltGap`.
                boltImage.draw(in: rect, from: ink ?? .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            for (index, line) in lines.enumerated() {
                if index > 0 { x += percentGap }
                let ink = MenuBarNumericImage.ink(line)
                ctx.textPosition = CGPoint(x: snap(x - ink.minX), y: snap(height - baseline))
                CTLineDraw(line, ctx)
                x += ink.width
            }
        }
    }

    // MARK: Battery rounded frame (optional)

    /// The thin rounded frame of `BatteryFrameStyle.rounded` (design "B", 2026-10-28). It surrounds the
    /// unchanged minimal image, which is drawn whole-point offset (never resampled), so numbers, `%`, bolt, green
    /// and centring stay exactly the minimal ones.
    enum BatteryFrame {
        static let stroke: CGFloat = 0.75
        static let alpha: CGFloat = 0.55
        static let radius: CGFloat = 3.5
        /// Clear space from the content's ink to the stroke's centre line, minus half the stroke.
        static let paddingX: CGFloat = 2.25
        /// 17.5 pt frame height (2026-10-28; was 1.75 for 15.75 pt): as tall as the AI widgets' ink.
        static let paddingY: CGFloat = 2.625
        /// Added on each side of the minimal image: `paddingX + stroke` rounded up to whole points.
        static let grow: CGFloat = (paddingX + stroke).rounded(.up)
        /// Fixed from the bolt (the tallest content), so the frame does not change height with the bolt.
        static var height: CGFloat { BatteryStyle.standard.boltHeight + 2 * paddingY + stroke }
    }

    /// Frames a rendered minimal battery image. Horizontally the frame follows the content's drawn ink (so it
    /// hugs `82%` as closely as `⚡100%`); vertically it is the fixed `BatteryFrame.height`, centred.
    static func framed(_ base: CGImage, dimmed: Bool, dark: Bool, scale: Int) -> CGImage? {
        let s = CGFloat(scale), grow = Int(BatteryFrame.grow)
        let width = base.width + 2 * grow * scale, height = base.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: grow * scale, y: 0, width: base.width, height: base.height))
        // Ink columns of the minimal image (premultiplied RGBA, so alpha is the 4th byte).
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        var left = Int.max, right = -1
        for y in 0..<height { for x in 0..<width where data[y * bytesPerRow + x * 4 + 3] > 0 {
            left = min(left, x); right = max(right, x)
        } }
        guard right >= left else { return ctx.makeImage() }
        let stroke = BatteryFrame.stroke
        // Stroke centre lines snapped so the line covers whole device pixels where it can.
        let snap: (CGFloat) -> CGFloat = { (($0 * s - stroke * s / 2).rounded() + stroke * s / 2) / s }
        let minX = snap(CGFloat(left) / s - BatteryFrame.paddingX - stroke / 2)
        let maxX = snap(CGFloat(right + 1) / s + BatteryFrame.paddingX + stroke / 2)
        let minY = snap((MenuBarNumericImage.height - BatteryFrame.height) / 2)
        let maxY = snap((MenuBarNumericImage.height + BatteryFrame.height) / 2)
        ctx.scaleBy(x: s, y: s)
        let alpha = BatteryFrame.alpha * (dimmed ? MenuBarNumericImage.staleAlpha : 1)
        ctx.setStrokeColor(textColor(dark: dark).copy(alpha: alpha)!)
        ctx.setLineWidth(stroke)
        ctx.addPath(CGPath(roundedRect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                           cornerWidth: BatteryFrame.radius, cornerHeight: BatteryFrame.radius, transform: nil))
        ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: Shared

    /// The bitmap set-up of `MenuBarNumericImage.render`: sRGB, premultiplied alpha, point scale, no font
    /// smoothing, and positions snapped to the pixel grid.
    private static func draw(size: CGSize, scale: Int, _ body: (CGContext, (CGFloat) -> CGFloat) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setShouldSmoothFonts(false)
        body(ctx) { ($0 * CGFloat(scale)).rounded() / CGFloat(scale) }
        return ctx.makeImage()
    }

    /// Image for one widget; non-template so the colours (and the green bolt) are kept, like the AI labels.
    /// `style` applies to CPU·RAM·Disk·GPU only; Battery is one row and ignores it. `frame` applies to Battery only.
    static func render(_ display: SystemWidgetDisplay, dark: Bool, scale: Int, style: SystemWidgetLayout = .unified,
                       frame: BatteryFrameStyle = .minimal) -> CGImage? {
        if display.widget == .battery {
            guard let minimal = renderBattery(display, dark: dark, scale: scale) else { return nil }
            return frame == .rounded ? framed(minimal, dimmed: display.isDimmed, dark: dark, scale: scale) : minimal
        }
        return render(column(display), width: fixedWidth(name: display.widget.title, value: display.value), dark: dark,
                      scale: scale, style: style)
    }

    static func size(_ display: SystemWidgetDisplay, frame: BatteryFrameStyle = .minimal) -> CGSize {
        guard display.widget == .battery else { return size(width: fixedWidth(name: display.widget.title, value: display.value)) }
        let minimal = size(width: batteryWidth(display))
        guard frame == .rounded else { return minimal }
        return CGSize(width: minimal.width + 2 * BatteryFrame.grow, height: minimal.height)
    }

    @MainActor
    static func make(_ display: SystemWidgetDisplay, dark: Bool) -> NSImage? {
        make(display, dark: dark, scale: max(2, Int((NSScreen.main?.backingScaleFactor ?? 2).rounded())))
    }

    /// For a known pixel scale (the label passes its environment's `displayScale`).
    static func make(_ display: SystemWidgetDisplay, dark: Bool, scale: Int, style: SystemWidgetLayout = .unified,
                     frame: BatteryFrameStyle = .minimal) -> NSImage? {
        guard let image = render(display, dark: dark, scale: max(scale, 1), style: style, frame: frame) else { return nil }
        let result = NSImage(cgImage: image, size: size(display, frame: frame))
        result.isTemplate = false
        return result
    }
}

/// How CPU·RAM·Disk·GPU arrange their two rows (settings > 테마 "시스템 위젯 표시 방식"). Battery is one row and
/// is not affected. The AI widgets never read this.
enum SystemWidgetLayout: String, CaseIterable, Identifiable {
    /// Number above, name below, like the AI numeric widgets. Default.
    case unified
    /// Name above, number below, so system widgets read differently from the AI ones.
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: "통일형 — 숫자 위 / 이름 아래"
        case .split: "구분형 — 이름 위 / 숫자 아래"
        }
    }

    /// The style a widget is actually drawn with: Battery always `unified` (it has no name row).
    func applied(to widget: SystemWidget) -> SystemWidgetLayout {
        widget == .battery ? .unified : self
    }
}

/// Battery look (settings > 테마 "배터리 표시 스타일"). The bolt policy, centring, size and colours are the same
/// in both; `rounded` only adds a thin frame around them.
enum BatteryFrameStyle: String, CaseIterable, Identifiable {
    /// Number (and bolt) only. Default.
    case minimal
    /// The same, inside a thin rounded rectangle (about 6 pt wider).
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: "미니멀형"
        case .rounded: "라운드 테두리형"
        }
    }

    /// The frame a widget is actually drawn with: only Battery has one.
    func applied(to widget: SystemWidget) -> BatteryFrameStyle {
        widget == .battery ? self : .minimal
    }
}

extension SystemWidgetDisplay.Value {
    var isPercent: Bool {
        if case .percent = self { return true }
        return false
    }
}
