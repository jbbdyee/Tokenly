import AppKit
import CryptoKit
import XCTest
@testable import Tokenly

/// Pixel checks for the system widget images. They run on this Mac's fonts and symbols; the real menu bar
/// (tinting, item spacing, order) is checked by hand in 6-3.
final class MenuBarSystemImageTests: XCTestCase {
    private let scale = 2

    // MARK: Pixel helpers

    private struct Pixels: Equatable {
        let width: Int
        let height: Int
        let data: [UInt8]

        /// Straight (un-premultiplied) RGBA, 0...255.
        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            let a = Double(data[i + 3])
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(data[i]) * 255 / a, Double(data[i + 1]) * 255 / a, Double(data[i + 2]) * 255 / a, a)
        }

        /// Rows and columns that hold any ink.
        var inkBounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var bounds: (Int, Int, Int, Int)?
            for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] > 0 {
                bounds = bounds.map { (min($0.0, x), max($0.1, x), min($0.2, y), max($0.3, y)) } ?? (x, x, y, y)
            } }
            return bounds.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
        }

        func maxAlpha(rows: Range<Int>) -> Double {
            var best = 0.0
            for y in rows { for x in 0..<width { best = max(best, Double(data[(y * width + x) * 4 + 3])) } }
            return best
        }

        func count(_ predicate: ((r: Double, g: Double, b: Double, a: Double)) -> Bool) -> Int {
            var total = 0
            for y in 0..<height { for x in 0..<width where predicate(rgba(x, y)) { total += 1 } }
            return total
        }
    }

    private func pixels(_ image: CGImage?, file: StaticString = #filePath, line: UInt = #line) throws -> Pixels {
        let image = try XCTUnwrap(image, file: file, line: line)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, data: data)
    }

    private func display(_ widget: SystemWidget, _ value: SystemWidgetDisplay.Value, charging: Bool = false) -> SystemWidgetDisplay {
        SystemWidgetDisplay(widget: widget, value: value, bolt: charging ? .charging : .none)
    }

    /// Pixel rows holding opaque digit ink (alpha > 128), above the name row.
    private func digitRows(_ image: Pixels, below limit: Int) -> (minY: Int, maxY: Int)? {
        var rows: (minY: Int, maxY: Int)?
        for y in 0..<limit { for x in 0..<image.width where image.rgba(x, y).a > 128 && !isGreen(image.rgba(x, y)) {
            rows = (min(rows?.minY ?? y, y), max(rows?.maxY ?? y, y))
        } }
        return rows
    }

    private let twoRow: [SystemWidget] = [.cpu, .memory, .disk, .gpu]
    private let values: [SystemWidgetDisplay.Value] = [.percent(0), .percent(9), .percent(24), .percent(99), .percent(100), .loading, .unavailable]

    // MARK: 1. Shared rules = the AI renderer

    /// Same text, no `%`, natural width: the system column must equal the AI AGY column pixel for pixel. This
    /// covers fonts, weights, baselines, ink centring, snapping and colours for digits and name; not the `%`, the
    /// fixed width, the battery row or the real menu bar. Compared with the AI layout before AGY's 0.5 pt number
    /// lift (`singleNumberLift = 0`), which the system widgets do not take.
    private let aiWithoutLift: MenuBarNumericImage.Layout = {
        var layout = MenuBarNumericImage.Layout.standard
        layout.singleNumberLift = 0
        return layout
    }()

    func testSharedRulesMatchTheAGYColumnPixelForPixel() throws {
        for dark in [false, true] {
            for stale in [false, true] {
                let agy = NumericGaugeItem(provider: .antigravity, primary: 51, secondary: nil, hasSecondarySlot: false, stale: stale)
                let ai = try pixels(MenuBarNumericImage.render([agy], dark: dark, scale: scale, layout: aiWithoutLift))
                let system = try pixels(MenuBarSystemImage.render(.init(digits: "51", suffix: nil, name: "AGY", dimmed: stale),
                                                                  width: nil, dark: dark, scale: scale,
                                                                  aiPadding: true))
                XCTAssertEqual(system.width, ai.width)
                XCTAssertEqual(system.height, ai.height)
                XCTAssertTrue(system == ai, "dark=\(dark) stale=\(stale): pixels differ")
            }
        }
    }

    // MARK: 2. Fixed width

    /// 0 % to 99 %, `—` and loading share one width; only 100 % is wider (6-3 spacing revision).
    func testWidthStaysFixedBelowAHundred() throws {
        let belowHundred = (0...99).map { SystemWidgetDisplay.Value.percent($0) } + [.loading, .unavailable]
        for widget in twoRow {
            let sizes = Set(belowHundred.map { MenuBarSystemImage.size(display(widget, $0)) }.map { "\($0)" })
            XCTAssertEqual(sizes.count, 1, "\(widget) changes size: \(sizes)")
            let widths = try Set(values.filter { $0 != .percent(100) }.map {
                try pixels(MenuBarSystemImage.render(display(widget, $0), dark: false, scale: scale)).width
            })
            XCTAssertEqual(widths.count, 1)
            XCTAssertGreaterThanOrEqual(MenuBarSystemImage.size(display(widget, .percent(100))).width,
                                        MenuBarSystemImage.size(display(widget, .percent(24))).width)
            XCTAssertEqual(MenuBarSystemImage.size(display(widget, .percent(0))).height, MenuBarNumericImage.height)
        }
        for charging in [false, true] {
            let battery = Set(belowHundred.map { MenuBarSystemImage.size(display(.battery, $0, charging: charging)) }.map { "\($0)" })
            XCTAssertEqual(battery.count, 1, "charging=\(charging): readings below 100 % never resize the battery item")
        }
    }

    // MARK: 2-1. Spacing (6-3 revision)

    func testSidePaddingIsHalfAPointAndTheColumnIsTwoDigitsWide() {
        XCTAssertEqual(MenuBarSystemImage.itemPadding, 0.5)
        XCTAssertEqual(MenuBarNumericImage.sidePadding, 1, "The AI padding is unchanged")
        XCTAssertLessThan(MenuBarSystemImage.twoDigitWidth, MenuBarSystemImage.hundredWidth - 4,
                          "Two digits are clearly narrower than 100%")
        for widget in twoRow {
            let width = MenuBarSystemImage.fixedWidth(name: widget.title, value: .percent(24))
            XCTAssertEqual(MenuBarSystemImage.size(display(widget, .percent(24))).width, (1 + width).rounded(.up))
        }
        for widget in [SystemWidget.cpu, .memory] {
            XCTAssertEqual(MenuBarSystemImage.fixedWidth(name: widget.title, value: .percent(24)), MenuBarSystemImage.twoDigitWidth,
                           "\(widget): the digits, not the name, set the width")
        }
    }

    /// The widest two-digit value leaves at most padding + rounding + antialiasing empty on each side.
    func testEmptyMarginAroundTheWidestTwoDigitsIsSmall() throws {
        let widest = (10...99).max { a, b in
            numberInkWidth("\(a)") < numberInkWidth("\(b)")
        }!
        for scale in [2, 3] {
            for widget in [SystemWidget.cpu, .memory] {
                let image = try pixels(MenuBarSystemImage.render(display(widget, .percent(widest)), dark: false, scale: scale))
                let digits = try XCTUnwrap(digitRowsInk(image))
                let limit = Double(scale) * (0.5 + 1) + 1
                XCTAssertLessThanOrEqual(Double(digits.minX), limit, "\(scale)x \(widget) \(widest)%: left margin")
                XCTAssertLessThanOrEqual(Double(image.width - 1 - digits.maxX), limit, "\(scale)x \(widget) \(widest)%: right margin")
            }
        }
    }

    /// Columns holding digit ink in the top half (above the name).
    private func digitRowsInk(_ image: Pixels) -> (minX: Int, maxX: Int)? {
        let limit = Int((MenuBarNumericImage.vertical(MenuBarSystemImage.layout).singleBaseline + 1) * CGFloat(image.height) / MenuBarNumericImage.height)
        var columns: (minX: Int, maxX: Int)?
        for y in 0..<limit { for x in 0..<image.width where image.rgba(x, y).a > 0 {
            columns = (min(columns?.minX ?? x, x), max(columns?.maxX ?? x, x))
        } }
        return columns
    }

    // MARK: 2-2. Vertical alignment with the AI numeric style

    /// CPU·RAM·Disk·GPU and AGY digits occupy the same pixel rows: same top, same baseline, same 22 pt height.
    /// Battery is one row and is centred in the image instead (`testBatteryIsCentredInTheImage`).
    func testDigitsShareTopAndBaselineAcrossWidgetsAndAGY() throws {
        for scale in [2, 3] {
            let limit = Int((MenuBarNumericImage.vertical(MenuBarSystemImage.layout).singleBaseline + 1) * CGFloat(scale))
            let agyItem = NumericGaugeItem(provider: .antigravity, primary: 50, secondary: nil, hasSecondarySlot: false, stale: false)
            // The AGY digit band before AGY's own 0.5 pt lift: the system digits keep it.
            let agy = try XCTUnwrap(digitRows(try pixels(MenuBarNumericImage.render([agyItem], dark: false, scale: scale,
                                                                                    layout: aiWithoutLift)), below: limit))
            for display in [display(.cpu, .percent(50)), display(.memory, .percent(50)), display(.disk, .percent(50)),
                            display(.gpu, .percent(50))] {
                let image = try pixels(MenuBarSystemImage.render(display, dark: false, scale: scale))
                XCTAssertEqual(image.height, Int(MenuBarNumericImage.height) * scale)
                let rows = try XCTUnwrap(digitRows(image, below: limit), "\(display)")
                XCTAssertEqual(rows.minY, agy.minY, "\(scale)x \(display): digit top differs from AGY")
                XCTAssertEqual(rows.maxY, agy.maxY, "\(scale)x \(display): digit baseline differs from AGY")
            }
            // Names share the AI name baseline.
            let cpu = try pixels(MenuBarSystemImage.render(display(.cpu, .percent(50)), dark: false, scale: scale))
            let agyImage = try pixels(MenuBarNumericImage.render([agyItem], dark: false, scale: scale))
            XCTAssertEqual(cpu.inkBounds?.maxY, agyImage.inkBounds?.maxY, "\(scale)x: name bottom differs from AGY")
        }
    }

    /// Battery (number alone, or bolt and number together) is centred in the 22 pt image at 2× and 3×, light and dark.
    func testBatteryIsCentredInTheImage() throws {
        XCTAssertEqual(MenuBarSystemImage.BatteryStyle.standard.baseline - MenuBarSystemImage.digitInk.midY,
                       MenuBarNumericImage.height / 2, accuracy: 0.001, "Digit ink centre on the image centre")
        let bolts: [SystemWidgetDisplay.Bolt] = [.none, .charging, .fullOnExternalPower]
        for scale in [2, 3] {
            for dark in [false, true] {
                for value in [0, 9, 24, 99, 100] {
                    for bolt in bolts {
                        let d = SystemWidgetDisplay(widget: .battery, value: .percent(value), bolt: bolt)
                        let image = try pixels(MenuBarSystemImage.render(d, dark: dark, scale: scale))
                        // Solid ink only, so faint antialiasing does not tip the centre.
                        var rows: (minY: Int, maxY: Int)?
                        for y in 0..<image.height { for x in 0..<image.width where image.rgba(x, y).a > 128 {
                            rows = (min(rows?.minY ?? y, y), max(rows?.maxY ?? y, y))
                        } }
                        let ink = try XCTUnwrap(rows)
                        XCTAssertEqual(Double(ink.minY + ink.maxY + 1) / 2, Double(image.height) / 2, accuracy: 1.0,
                                       "\(scale)x dark=\(dark) \(value)% \(bolt): group not centred")
                    }
                }
            }
        }
    }

    /// The bolt is a little larger than before (10 pt Medium) and taller than the digits, but inside the row.
    func testBoltIsLargerThanBeforeAndTallerThanTheDigits() throws {
        let style = MenuBarSystemImage.BatteryStyle.standard
        XCTAssertGreaterThan(style.boltHeight, MenuBarSystemImage.BatteryStyle.previous.boltHeight)
        XCTAssertGreaterThan(MenuBarSystemImage.boltSize().width, MenuBarSystemImage.boltSize(.previous).width)
        XCTAssertGreaterThan(style.boltHeight, MenuBarSystemImage.digitInk.height)
        XCTAssertLessThanOrEqual(style.boltHeight, MenuBarNumericImage.height - 8, "Leaves room above and below")
    }

    /// WCAG contrast of the bolt green against a white and a black menu bar. Light mode uses a deeper green
    /// than the system green the earlier bolt used (about 2.2 : 1 on white).
    func testBoltGreenContrast() {
        func luminance(_ color: CGColor) -> Double {
            let c = color.components!.prefix(3).map { Double($0) }
                .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        let light = luminance(MenuBarSystemImage.boltColor(dark: false))
        let dark = luminance(MenuBarSystemImage.boltColor(dark: true))
        let previous = luminance(CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1))
        XCTAssertGreaterThanOrEqual(1.05 / (light + 0.05), 3, "Light green on white")
        XCTAssertGreaterThan(1.05 / (light + 0.05), 1.05 / (previous + 0.05) + 1)
        XCTAssertGreaterThanOrEqual((dark + 0.05) / 0.05, 7, "Dark green on black")
    }

    /// Battery `%` is drawn at the same 75 % size and on the digits' baseline, like the two-row widgets' `%`.
    func testBatteryPercentMatchesTheTwoRowPercent() throws {
        /// Rows of the rightmost glyph (`%`): columns from the right edge of the ink to the first empty column,
        /// within `rows`.
        func percentRows(_ image: Pixels, rows: Range<Int>) throws -> (top: Int, bottom: Int) {
            func hasInk(_ x: Int) -> Bool { rows.contains { image.rgba(x, $0).a > 0 } }
            let right = try XCTUnwrap((0..<image.width).last(where: hasInk))
            var left = right
            while left > 0, hasInk(left - 1) { left -= 1 }
            var top = Int.max, bottom = -1
            for y in rows { for x in left...right where image.rgba(x, y).a > 128 { top = min(top, y); bottom = max(bottom, y) } }
            return (top, bottom)
        }
        func digitBottom(_ image: Pixels, rows: Range<Int>) -> Int {
            var bottom = -1
            for y in rows { for x in 0..<(image.width / 3) where image.rgba(x, y).a > 128 { bottom = max(bottom, y) } }
            return bottom
        }
        for scale in [2, 3] {
            let limit = Int((MenuBarNumericImage.vertical(MenuBarSystemImage.layout).singleBaseline + 1) * CGFloat(scale))
            let battery = try pixels(MenuBarSystemImage.render(display(.battery, .percent(82)), dark: false, scale: scale))
            let cpu = try pixels(MenuBarSystemImage.render(display(.cpu, .percent(82)), dark: false, scale: scale))
            let b = try percentRows(battery, rows: 0..<battery.height)
            let c = try percentRows(cpu, rows: 0..<limit)
            XCTAssertEqual(b.bottom - b.top, c.bottom - c.top, "\(scale)x: same % height")
            XCTAssertEqual(b.bottom, digitBottom(battery, rows: 0..<battery.height), accuracy: 1, "\(scale)x: battery % on the digits' baseline")
            XCTAssertEqual(c.bottom, digitBottom(cpu, rows: 0..<limit), accuracy: 1, "\(scale)x: CPU % on the digits' baseline")
        }
    }

    /// The bolt is centred on the digits.
    func testBoltIsCentredOnTheDigits() throws {
        let scale = 3
        let image = try pixels(MenuBarSystemImage.render(display(.battery, .percent(82), charging: true), dark: false, scale: scale))
        var bolt: (minY: Int, maxY: Int)?
        for y in 0..<image.height { for x in 0..<image.width where isGreen(image.rgba(x, y)) {
            bolt = (min(bolt?.minY ?? y, y), max(bolt?.maxY ?? y, y))
        } }
        let boltRows = try XCTUnwrap(bolt)
        let digits = try XCTUnwrap(digitRows(image, below: image.height))
        XCTAssertEqual(Double(boltRows.minY + boltRows.maxY) / 2, Double(digits.minY + digits.maxY) / 2, accuracy: 1.5)
    }

    // MARK: 3. `%` baseline and size

    func testPercentSharesTheBaselineAtTheSecondarySize() throws {
        let laidOut = MenuBarSystemImage.runs(.init(digits: "24", suffix: "%", name: "CPU", dimmed: false),
                                              width: MenuBarSystemImage.fixedWidth(name: "CPU"), dark: false)
        XCTAssertEqual(laidOut.runs.count, 3)
        XCTAssertEqual(laidOut.runs[0].baseline, laidOut.runs[1].baseline, "% sits on the digits' baseline")
        XCTAssertEqual(laidOut.runs[0].baseline, MenuBarNumericImage.vertical(MenuBarSystemImage.layout).singleBaseline)
        XCTAssertEqual(laidOut.runs[2].baseline, MenuBarNumericImage.vertical(MenuBarSystemImage.layout).nameBaseline)

        func fontSize(_ line: CTLine) throws -> CGFloat {
            let run = try XCTUnwrap((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont
            return CTFontGetSize(font)
        }
        let layout = MenuBarSystemImage.layout
        XCTAssertEqual(try fontSize(laidOut.runs[0].line), layout.primarySize)
        XCTAssertEqual(try fontSize(laidOut.runs[1].line), layout.primarySize * 0.75, accuracy: 0.001, "% is 75 % of the digits")
        XCTAssertEqual(MenuBarSystemImage.percentRatio, 0.75)
        XCTAssertEqual(layout.secondaryRatio, 0.8, "The AI secondary ratio is unchanged")
        XCTAssertEqual(try fontSize(laidOut.runs[2].line), layout.nameSize)
    }

    // MARK: 4. Centring

    func testDigitsAndNameAreCentredInTheFixedColumn() {
        for widget in twoRow {
                for value in values {
                let width = MenuBarSystemImage.fixedWidth(name: widget.title, value: value)
                let laidOut = MenuBarSystemImage.runs(MenuBarSystemImage.column(display(widget, value)), width: width, dark: false)
                let digitRuns = laidOut.runs.dropLast()
                let inks = digitRuns.map { ($0.x + MenuBarNumericImage.ink($0.line).minX, $0.x + MenuBarNumericImage.ink($0.line).maxX) }
                let digitsCentre = ((inks.map(\.0).min() ?? 0) + (inks.map(\.1).max() ?? 0)) / 2
                let name = laidOut.runs.last!
                let nameInk = MenuBarNumericImage.ink(name.line)
                XCTAssertEqual(digitsCentre, width / 2, accuracy: 0.01, "\(widget) \(value) digits")
                XCTAssertEqual(name.x + nameInk.midX, width / 2, accuracy: 0.01, "\(widget) name")
            }
        }
    }

    // MARK: 5. Dimmed states

    func testNotYetMeasuredIsDimmedAndUnavailableIsNot() throws {
        let split = Int((MenuBarNumericImage.vertical(MenuBarSystemImage.layout).singleBaseline + 1) * CGFloat(scale))
        for dark in [false, true] {
            let loading = try pixels(MenuBarSystemImage.render(display(.cpu, .loading), dark: dark, scale: scale))
            let unavailable = try pixels(MenuBarSystemImage.render(display(.cpu, .unavailable), dark: dark, scale: scale))
            let normal = try pixels(MenuBarSystemImage.render(display(.cpu, .percent(24)), dark: dark, scale: scale))
            XCTAssertEqual(loading.maxAlpha(rows: 0..<split), 128, accuracy: 3, "Loading dash at the AI stale alpha")
            XCTAssertGreaterThan(unavailable.maxAlpha(rows: 0..<split), 250)
            XCTAssertGreaterThan(normal.maxAlpha(rows: 0..<split), 250)
            XCTAssertGreaterThan(loading.maxAlpha(rows: split..<loading.height), 250, "The name is never dimmed")
        }
        let batteryLoading = try pixels(MenuBarSystemImage.render(SystemWidgetPresentation.battery(nil), dark: false, scale: scale))
        XCTAssertLessThanOrEqual(batteryLoading.maxAlpha(rows: 0..<batteryLoading.height), 131, "The dash is dimmed before the first sample")
    }

    // MARK: 6. Light and dark

    func testLightIsBlackAndDarkIsWhiteWithoutColour() throws {
        for widget in twoRow {
            let light = try pixels(MenuBarSystemImage.render(display(widget, .percent(71)), dark: false, scale: scale))
            let dark = try pixels(MenuBarSystemImage.render(display(widget, .percent(71)), dark: true, scale: scale))
            XCTAssertGreaterThan(light.count { $0.a > 200 && $0.r < 30 && $0.g < 30 && $0.b < 30 }, 0)
            XCTAssertEqual(light.count { $0.a > 60 && ($0.r > 60 || $0.g > 60 || $0.b > 60) }, 0)
            XCTAssertGreaterThan(dark.count { $0.a > 200 && $0.r > 225 && $0.g > 225 && $0.b > 225 }, 0)
            XCTAssertEqual(dark.count { $0.a > 60 && ($0.r < 195 || $0.g < 195 || $0.b < 195) }, 0)
        }
    }

    // MARK: 7. Battery: number only, bolt while charging, no outline

    private func isGreen(_ p: (r: Double, g: Double, b: Double, a: Double)) -> Bool {
        p.a > 128 && p.g > p.r + 60 && p.g > p.b + 60
    }

    /// Ink width the number itself should take: digits, the AI separator gap, `%`.
    private func numberInkWidth(_ digits: String) -> CGFloat {
        let layout = MenuBarSystemImage.layout
        let black = MenuBarSystemImage.textColor(dark: false)
        let number = MenuBarNumericImage.ink(MenuBarNumericImage.line(digits, MenuBarNumericImage.font(layout.primarySize, weight: layout.primaryWeight), black))
        let percent = MenuBarNumericImage.ink(MenuBarNumericImage.line("%", MenuBarNumericImage.font(layout.primarySize * MenuBarSystemImage.percentRatio, weight: layout.secondaryWeight), black))
        return number.width + MenuBarSystemImage.percentGap + percent.width
    }

    func testNotChargingIsTheNumberAloneCentred() throws {
        for value in [5, 57, 82, 100] {
            for dark in [false, true] {
                let image = try pixels(MenuBarSystemImage.render(display(.battery, .percent(value)), dark: dark, scale: scale))
                let ink = try XCTUnwrap(image.inkBounds)
                XCTAssertEqual(image.count(isGreen), 0)
                // No outline or icon: the ink is just the number's width. ±3 px covers the antialiased column at
                // each outer edge plus snapping the digits and `%` runs separately; an outline would add ~40 px.
                XCTAssertEqual(Double(ink.maxX - ink.minX + 1), Double(numberInkWidth("\(value)") * CGFloat(scale)), accuracy: 3,
                               "\(value)%: extra ink beside the number")
                XCTAssertEqual(Double(ink.minX + ink.maxX) / 2, Double(image.width - 1) / 2, accuracy: 1.5,
                               "\(value)%: centred, no empty icon slot on one side")
            }
        }
    }

    func testChargingBoltSitsJustLeftOfTheNumberAtAConstantGap() throws {
        var gaps: Set<Int> = []
        for value in [5, 57, 82, 100] {
            let image = try pixels(MenuBarSystemImage.render(display(.battery, .percent(value), charging: true), dark: false, scale: scale))
            func column(_ x: Int, _ test: ((r: Double, g: Double, b: Double, a: Double)) -> Bool) -> Bool {
                (0..<image.height).contains { test(image.rgba(x, $0)) }
            }
            let boltRight = try XCTUnwrap((0..<image.width).last { column($0, isGreen) })
            // The number is black in light mode; the bolt's antialiased edge is faint green, never black.
            let numberLeft = try XCTUnwrap((0..<image.width).first { column($0) { $0.a > 128 && $0.r < 80 && $0.g < 80 && $0.b < 80 } })
            XCTAssertLessThan(boltRight, numberLeft, "\(value)%: the bolt is left of the number")
            // The gap is the run of columns with no ink at all between the two (antialiased edges excluded).
            gaps.insert(((boltRight + 1)..<numberLeft).filter { !column($0) { $0.a > 0 } }.count)
            let ink = try XCTUnwrap(image.inkBounds)
            XCTAssertEqual(Double(ink.minX + ink.maxX) / 2, Double(image.width - 1) / 2, accuracy: 1.5, "\(value)%: bolt and number centred")
        }
        XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, 1, "Constant bolt gap: \(gaps)")
        XCTAssertGreaterThanOrEqual(gaps.min()!, 1, "Bolt and number do not touch")
        XCTAssertLessThanOrEqual(gaps.max()!, Int(MenuBarSystemImage.BatteryStyle.standard.boltGap * CGFloat(scale)) + 1,
                                 "Clear gap is boltGap plus at most one snapped pixel: \(gaps)")
    }

    // MARK: 8. Bolt only while charging

    func testGreenBoltOnlyWhileChargingOrFullOnExternalPower() throws {
        func power(_ charging: SystemMetric<Bool>, connected: Bool, percent: Int = 82,
                   full: SystemMetric<Bool> = .available(false)) -> SystemMetric<BatteryPowerState> {
            .available(BatteryPowerState(chargePercent: .available(percent), isExternalPowerConnected: .available(connected),
                                         isCharging: charging, isAtFullCapacity: full))
        }
        func greenPixels(_ display: SystemWidgetDisplay, dark: Bool) throws -> Int {
            try pixels(MenuBarSystemImage.render(display, dark: dark, scale: scale)).count {
                $0.a > 128 && $0.g > $0.r + 60 && $0.g > $0.b + 60
            }
        }
        for dark in [false, true] {
            XCTAssertGreaterThan(try greenPixels(SystemWidgetPresentation.battery(power(.available(true), connected: true)), dark: dark), 0)
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(power(.available(false), connected: true)), dark: dark), 0,
                           "Plugged in but not charging")
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(power(.available(false), connected: false)), dark: dark), 0)
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(power(.unavailable(.unsupported), connected: true)), dark: dark), 0)
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(nil), dark: dark), 0)
            XCTAssertGreaterThan(try greenPixels(SystemWidgetPresentation.battery(
                power(.available(false), connected: true, percent: 100, full: .available(true))), dark: dark), 0, "⚡100%")
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(
                power(.available(false), connected: true, percent: 100, full: .available(false))), dark: dark), 0,
                           "Rounded 100 but not full: no bolt")
            XCTAssertEqual(try greenPixels(SystemWidgetPresentation.battery(
                power(.available(false), connected: false, percent: 100, full: .available(true))), dark: dark), 0,
                           "Full on battery: no bolt")
        }
    }

    // MARK: 9. Nothing clipped

    func testInkStaysInsideTheTwentyTwoPointRowAtTwoAndThreeTimes() throws {
        var cases: [SystemWidgetDisplay] = twoRow.flatMap { widget in [0, 9, 24, 99, 100].map { display(widget, .percent($0)) } + [display(widget, .unavailable)] }
        cases += [false, true].flatMap { charging in
            [0, 9, 24, 99, 100].map { display(.battery, .percent($0), charging: charging) }
                + [display(.battery, .unavailable), display(.battery, .loading)]
        }
        for scale in [2, 3] {
            for display in cases {
                for dark in [false, true] {
                    let image = try pixels(MenuBarSystemImage.render(display, dark: dark, scale: scale))
                    XCTAssertEqual(image.height, Int(MenuBarNumericImage.height) * scale)
                    XCTAssertEqual(image.width, Int(MenuBarSystemImage.size(display).width) * scale)
                    let ink = try XCTUnwrap(image.inkBounds, "\(display) draws nothing")
                    XCTAssertGreaterThanOrEqual(ink.minY, 1, "\(scale)x \(display) touches the top")
                    XCTAssertLessThanOrEqual(ink.maxY, image.height - 2, "\(scale)x \(display) touches the bottom")
                    // With the 0.5 pt side padding an antialiased edge may reach the outermost column; a glyph cut
                    // by the edge would leave solid ink there instead.
                    func edgeAlpha(_ x: Int) -> Double { (0..<image.height).map { image.rgba(x, $0).a }.max() ?? 0 }
                    XCTAssertLessThan(edgeAlpha(0), 160, "\(scale)x \(display) is cut at the left edge")
                    XCTAssertLessThan(edgeAlpha(image.width - 1), 160, "\(scale)x \(display) is cut at the right edge")
                }
            }
        }
    }

    /// The bolt alone, then the number alone, each inside the row (charging, 3x).
    func testBatteryComponentsStayInsideTheRow() throws {
        let image = try pixels(MenuBarSystemImage.render(display(.battery, .percent(100), charging: true), dark: true, scale: 3))
        var bolt: (minY: Int, maxY: Int)?
        var number: (minY: Int, maxY: Int)?
        for y in 0..<image.height { for x in 0..<image.width where image.rgba(x, y).a > 0 {
            if isGreen(image.rgba(x, y)) { bolt = (min(bolt?.minY ?? y, y), max(bolt?.maxY ?? y, y)) }
            else if image.rgba(x, y).a > 128 { number = (min(number?.minY ?? y, y), max(number?.maxY ?? y, y)) }
        } }
        for (name, part) in [("bolt", bolt), ("number", number)] {
            let part = try XCTUnwrap(part, name)
            XCTAssertGreaterThanOrEqual(part.minY, 1, name)
            XCTAssertLessThanOrEqual(part.maxY, image.height - 2, name)
        }
    }

    func testBoltSymbolExistsOnThisMac() {
        XCTAssertNotNil(NSImage(systemSymbolName: MenuBarSystemImage.boltSymbolName, accessibilityDescription: nil))
        XCTAssertGreaterThan(MenuBarSystemImage.boltSize().width, 0)
    }

    // MARK: 10. Display style (6-3 follow-up): unified vs split

    private func styled(_ widget: SystemWidget, _ value: SystemWidgetDisplay.Value, _ style: SystemWidgetLayout,
                        dark: Bool = false, scale: Int = 2) throws -> Pixels {
        try pixels(MenuBarSystemImage.render(display(widget, value), dark: dark, scale: scale, style: style))
    }

    /// Pins the unified images. First recorded from the renderer before the style option existed (proving the
    /// option changed nothing); re-recorded on 2026-10-28 for the approved 1.7 pt number–`%` gap, the only change
    /// since (dash states and GPU 100% at 2× round to the same pixels and kept their hashes). Verified Mac
    /// (macOS 27.0.1) only; fonts differ elsewhere, so other systems skip.
    func testUnifiedIsPixelIdenticalToTheRendererBeforeTheOption() throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard (os.majorVersion, os.minorVersion, os.patchVersion) == (27, 0, 1) else {
            throw XCTSkip("Golden hashes were recorded on macOS 27.0.1")
        }
        let golden: [(SystemWidget, SystemWidgetDisplay.Value, Bool, Int, String)] = [
            (.cpu, .percent(9), true, 2, "53f919c334c37395"), (.cpu, .percent(24), false, 2, "3cdebfc7cb8a7a15"),
            (.cpu, .percent(24), false, 3, "ab1d852ec145764f"), (.cpu, .percent(24), true, 2, "ba30250e41a48ac9"),
            (.cpu, .percent(24), true, 3, "76f7d07d04730e98"), (.cpu, .percent(99), false, 3, "29a7407ac5591245"),
            (.memory, .loading, true, 3, "371be5a5cf3293b2"), (.disk, .percent(0), true, 3, "65281013fdc5c5bc"),
            (.disk, .unavailable, false, 3, "b2186df9aefdbf27"), (.gpu, .percent(100), false, 2, "46b6e59dff9f61b1"),
        ]
        for (widget, value, dark, scale, hash) in golden {
            for image in [MenuBarSystemImage.render(display(widget, value), dark: dark, scale: scale),
                          MenuBarSystemImage.render(display(widget, value), dark: dark, scale: scale, style: .unified)] {
                let data = try XCTUnwrap(image?.dataProvider?.data) as Data
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(String(digest.prefix(16)), hash, "\(widget) \(value) dark=\(dark) \(scale)x")
            }
        }
    }

    func testSplitBaselinesMirrorTheUnifiedBox() {
        let unified = MenuBarSystemImage.baselines(.unified)
        let split = MenuBarSystemImage.baselines(.split)
        let v = MenuBarNumericImage.vertical(MenuBarSystemImage.layout)
        XCTAssertEqual(unified, .init(digits: v.singleBaseline, name: v.nameBaseline), "Unified is the AGY column")
        XCTAssertLessThan(split.name, split.digits, "Name above, number below")
        let digitCap = MenuBarSystemImage.digitInk.maxY, nameCap = MenuBarSystemImage.nameCapInk.maxY
        // The mirrored box raised by exactly `splitLift` (2 pt): top (cap top of the upper row) and bottom
        // (baseline of the lower row).
        XCTAssertEqual(MenuBarSystemImage.splitLift, 2)
        XCTAssertEqual(split.name - nameCap, unified.digits - digitCap - 2, accuracy: 0.001)
        XCTAssertEqual(split.digits, unified.name - 2, accuracy: 0.001)
        XCTAssertEqual(split.digits, 17.40, accuracy: 0.01)
        XCTAssertEqual(split.name, 5.88, accuracy: 0.01)
        // Same clear space between the rows (lower row's cap top − upper row's baseline).
        XCTAssertEqual((split.digits - digitCap) - split.name, (unified.name - nameCap) - unified.digits, accuracy: 0.001)
    }

    func testSplitRunsPutTheNameAboveAndPercentOnTheDigitBaseline() throws {
        let width = MenuBarSystemImage.fixedWidth(name: "CPU", value: .percent(24))
        let laidOut = MenuBarSystemImage.runs(.init(digits: "24", suffix: "%", name: "CPU", dimmed: false), width: width,
                                              dark: false, style: .split)
        let split = MenuBarSystemImage.baselines(.split)
        XCTAssertEqual(laidOut.runs.map(\.baseline), [split.digits, split.digits, split.name])
        func fontSize(_ line: CTLine) throws -> CGFloat {
            let run = try XCTUnwrap((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
            return CTFontGetSize((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont)
        }
        let layout = MenuBarSystemImage.layout
        XCTAssertEqual(try fontSize(laidOut.runs[0].line), 12)
        XCTAssertEqual(try fontSize(laidOut.runs[1].line), layout.primarySize * 0.75, accuracy: 0.001)
        XCTAssertEqual(try fontSize(laidOut.runs[2].line), layout.nameSize)
        // Horizontal placement and width do not depend on the style.
        let unified = MenuBarSystemImage.runs(.init(digits: "24", suffix: "%", name: "CPU", dimmed: false), width: width, dark: false)
        XCTAssertEqual(laidOut.runs.map(\.x), unified.runs.map(\.x))
        XCTAssertEqual(laidOut.width, unified.width)
    }

    /// In pixels: the name's ink is above the digits' ink, the split block is the unified ink box raised by 2 pt,
    /// with the same row gap, and widths match.
    func testSplitPixelsNameAboveNumberBelow() throws {
        for scale in [2, 3] {
            for dark in [false, true] {
                for widget in twoRow {
                    let unified = try styled(widget, .percent(24), .unified, dark: dark, scale: scale)
                    let split = try styled(widget, .percent(24), .split, dark: dark, scale: scale)
                    XCTAssertEqual(split.width, unified.width)
                    XCTAssertEqual(split.height, unified.height)
                    // Rows with ink, grouped into bands separated by empty rows: [upper, lower].
                    func bands(_ image: Pixels) -> [(Int, Int)] {
                        var result: [(Int, Int)] = []
                        for y in 0..<image.height where (0..<image.width).contains(where: { image.rgba($0, y).a > 0 }) {
                            if let last = result.last, last.1 == y - 1 { result[result.count - 1].1 = y } else { result.append((y, y)) }
                        }
                        return result
                    }
                    let u = bands(unified), s = bands(split)
                    XCTAssertEqual(u.count, 2, "\(widget) unified bands \(u)")
                    XCTAssertEqual(s.count, 2, "\(widget) split bands \(s)")
                    guard u.count == 2, s.count == 2 else { continue }
                    // Upper band in split is the short name; lower is the taller number.
                    XCTAssertLessThan(s[0].1 - s[0].0, s[1].1 - s[1].0, "\(scale)x \(widget): name is the upper row")
                    XCTAssertEqual(s[0].1 - s[0].0, u[1].1 - u[1].0, accuracy: 1, "same name height")
                    XCTAssertEqual(s[1].1 - s[1].0, u[0].1 - u[0].0, accuracy: 1, "same number height")
                    XCTAssertEqual(s[0].0, u[0].0 - 2 * scale, accuracy: 1, "\(scale)x \(widget): top 2 pt higher")
                    XCTAssertEqual(s[1].1, u[1].1 - 2 * scale, accuracy: 1, "\(scale)x \(widget): bottom 2 pt higher")
                    XCTAssertEqual(s[1].0 - s[0].1, u[1].0 - u[0].1, accuracy: 1, "\(scale)x \(widget): same gap")
                }
            }
        }
    }

    func testSplitStaysInsideTheRowForEveryValue() throws {
        let values: [SystemWidgetDisplay.Value] = [.percent(0), .percent(9), .percent(24), .percent(99), .percent(100), .unavailable, .loading]
        for scale in [2, 3] { for dark in [false, true] { for widget in twoRow { for value in values {
            let image = try styled(widget, value, .split, dark: dark, scale: scale)
            XCTAssertEqual(image.height, Int(MenuBarNumericImage.height) * scale)
            XCTAssertEqual(image.width, Int(MenuBarSystemImage.size(display(widget, value)).width) * scale)
            let ink = try XCTUnwrap(image.inkBounds)
            XCTAssertGreaterThanOrEqual(ink.minY, 1, "\(scale)x \(widget) \(value) touches the top")
            XCTAssertLessThanOrEqual(ink.maxY, image.height - 2, "\(scale)x \(widget) \(value) touches the bottom")
            func edgeAlpha(_ x: Int) -> Double { (0..<image.height).map { image.rgba(x, $0).a }.max() ?? 0 }
            XCTAssertLessThan(edgeAlpha(0), 160, "\(scale)x \(widget) \(value) cut at the left")
            XCTAssertLessThan(edgeAlpha(image.width - 1), 160, "\(scale)x \(widget) \(value) cut at the right")
        } } } }
    }

    /// Split: the number (now the lower row) is dimmed while loading, the name never; colours as in unified.
    func testSplitDimmingAndColours() throws {
        let split = Int((MenuBarSystemImage.baselines(.split).name + 1) * CGFloat(scale))
        for dark in [false, true] {
            let loading = try styled(.cpu, .loading, .split, dark: dark)
            let normal = try styled(.cpu, .percent(24), .split, dark: dark)
            XCTAssertGreaterThan(loading.maxAlpha(rows: 0..<split), 250, "The name is never dimmed")
            XCTAssertEqual(loading.maxAlpha(rows: split..<loading.height), 128, accuracy: 3, "Loading dash dimmed")
            XCTAssertGreaterThan(normal.maxAlpha(rows: split..<normal.height), 250)
        }
        for widget in twoRow {
            let light = try styled(widget, .percent(71), .split, dark: false)
            let dark = try styled(widget, .percent(71), .split, dark: true)
            XCTAssertEqual(light.count { $0.a > 60 && ($0.r > 60 || $0.g > 60 || $0.b > 60) }, 0)
            XCTAssertEqual(dark.count { $0.a > 60 && ($0.r < 195 || $0.g < 195 || $0.b < 195) }, 0)
        }
    }

    func testBatteryIsTheSameInBothStyles() throws {
        for bolt in [SystemWidgetDisplay.Bolt.none, .charging, .fullOnExternalPower] {
            for scale in [2, 3] { for dark in [false, true] {
                let d = SystemWidgetDisplay(widget: .battery, value: .percent(bolt == .none ? 82 : 100), bolt: bolt)
                let unified = try pixels(MenuBarSystemImage.render(d, dark: dark, scale: scale, style: .unified))
                let split = try pixels(MenuBarSystemImage.render(d, dark: dark, scale: scale, style: .split))
                XCTAssertTrue(unified == split, "\(bolt) \(scale)x dark=\(dark)")
            } }
        }
    }

    /// 6-3 final: the split block's ink sits 2 pt (4 px at 2×, 6 px at 3×) above where the mirrored box put it,
    /// with the same internal gap; the visual weight moves up accordingly and stays inside the 22 pt row.
    func testSplitBlockIsRaisedByTwoPoints() throws {
        func inkRows(_ image: Pixels) -> (Int, Int) {
            var t = Int.max, b = -1
            for y in 0..<image.height { for x in 0..<image.width where image.rgba(x, y).a > 0 { t = min(t, y); b = max(b, y) } }
            return (t, b)
        }
        // At 3×, in points from the top: ink 1.33–17.67 for CPU 24% (measured in the approved preview).
        let image = try styled(.cpu, .percent(24), .split, scale: 3)
        let rows = inkRows(image)
        XCTAssertEqual(Double(rows.0) / 3, 1.33, accuracy: 0.34)
        XCTAssertEqual(Double(rows.1 + 1) / 3, 17.67, accuracy: 0.34)
        // Visual weight on the AI widgets' (12.76 unlifted, AI ≈ 10.8; preview 10.76).
        var weights: [Double] = []
        for widget in twoRow { for value in [24, 71, 99] {
            let px = try styled(widget, .percent(value), .split, scale: 3)
            var sum = 0.0, wy = 0.0
            for y in 0..<px.height { for x in 0..<px.width { let a = px.rgba(x, y).a; sum += a; wy += a * (Double(y) + 0.5) } }
            weights.append(wy / sum / 3)
        } }
        XCTAssertEqual(weights.reduce(0, +) / Double(weights.count), 10.76, accuracy: 0.2)
    }

    // MARK: 11. Battery rounded frame (6-3 final, design "B")

    private let batteryStates: [SystemWidgetDisplay] = [
        .init(widget: .battery, value: .percent(82)), .init(widget: .battery, value: .percent(82), bolt: .charging),
        .init(widget: .battery, value: .percent(100), bolt: .fullOnExternalPower), .init(widget: .battery, value: .percent(100)),
        .init(widget: .battery, value: .percent(5)), .init(widget: .battery, value: .unavailable), .init(widget: .battery, value: .loading),
    ]

    func testRoundedFrameValues() {
        typealias F = MenuBarSystemImage.BatteryFrame
        XCTAssertEqual(F.stroke, 0.75)
        XCTAssertEqual(F.alpha, 0.55)
        XCTAssertEqual(F.radius, 3.5)
        XCTAssertEqual(F.paddingX, 2.25)
        XCTAssertEqual(F.paddingY, 2.625)
        XCTAssertEqual(F.height, 17.5, accuracy: 0.001, "Approved 2026-10-28 (was 15.75)")
        XCTAssertEqual(F.grow, 3)
        XCTAssertEqual(BatteryFrameStyle.rounded.applied(to: .cpu), .minimal, "Only Battery has a frame")
    }

    /// The rounded image is the minimal image, unchanged and 3 pt in from each side, plus the frame: every minimal
    /// ink pixel is identical, the width grows by exactly 6 pt and the height stays 22 pt.
    func testRoundedFrameKeepsTheMinimalContentExactly() throws {
        for scale in [2, 3] { for dark in [false, true] { for state in batteryStates {
            let minimal = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale))
            let rounded = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale, frame: .rounded))
            XCTAssertEqual(rounded.width, minimal.width + 6 * scale)
            XCTAssertEqual(rounded.height, Int(MenuBarNumericImage.height) * scale)
            XCTAssertEqual(MenuBarSystemImage.size(state, frame: .rounded).width, MenuBarSystemImage.size(state).width + 6)
            let offset = 3 * scale
            var differs = 0
            for y in 0..<minimal.height { for x in 0..<minimal.width where minimal.rgba(x, y).a > 0 {
                let a = minimal.data[(y * minimal.width + x) * 4..<(y * minimal.width + x) * 4 + 4]
                let b = rounded.data[(y * rounded.width + x + offset) * 4..<(y * rounded.width + x + offset) * 4 + 4]
                if Array(a) != Array(b) { differs += 1 }
            } }
            XCTAssertEqual(differs, 0, "\(scale)x dark=\(dark) \(state): content changed under the frame")
        } } }
    }

    /// The frame: fixed height (same rows for every state), clear of the content on all sides, inside the 22 pt row
    /// and the image width, and drawn at 55 % (dimmed with the loading dash).
    func testRoundedFrameGeometry() throws {
        for scale in [2, 3] { for dark in [false, true] {
            var frameRows: Set<String> = []
            for state in batteryStates {
                let minimal = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale))
                let rounded = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale, frame: .rounded))
                let offset = 3 * scale
                // Frame pixels = ink in the rounded image that is not the minimal content.
                var frame: (l: Int, r: Int, t: Int, b: Int)?
                var content: (l: Int, r: Int, t: Int, b: Int)?
                var maxFrameAlpha = 0.0
                for y in 0..<rounded.height { for x in 0..<rounded.width where rounded.rgba(x, y).a > 0 {
                    let mx = x - offset
                    let isContent = mx >= 0 && mx < minimal.width && minimal.rgba(mx, y).a > 0
                    func grow(_ r: (l: Int, r: Int, t: Int, b: Int)?) -> (l: Int, r: Int, t: Int, b: Int) {
                        r.map { (min($0.l, x), max($0.r, x), min($0.t, y), max($0.b, y)) } ?? (x, x, y, y)
                    }
                    if isContent { content = grow(content) } else { frame = grow(frame); maxFrameAlpha = max(maxFrameAlpha, rounded.rgba(x, y).a) }
                } }
                let f = try XCTUnwrap(frame, "\(state): no frame"), c = try XCTUnwrap(content)
                frameRows.insert("\(f.t)-\(f.b)")
                XCTAssertGreaterThanOrEqual(f.t, 1); XCTAssertLessThanOrEqual(f.b, rounded.height - 2, "inside 22 pt")
                XCTAssertGreaterThanOrEqual(f.l, 0); XCTAssertLessThanOrEqual(f.r, rounded.width - 1)
                // Clear space between content ink and the frame's ink on every side (at least 1 pt horizontally,
                // 1 pt vertically for the tallest content, the bolt).
                XCTAssertGreaterThanOrEqual(c.l - f.l, 2 * scale, "\(scale)x \(state): left clearance")
                XCTAssertGreaterThanOrEqual(f.r - c.r, 2 * scale, "\(scale)x \(state): right clearance")
                XCTAssertGreaterThanOrEqual(c.t - f.t, scale, "\(scale)x \(state): top clearance")
                XCTAssertGreaterThanOrEqual(f.b - c.b, scale, "\(scale)x \(state): bottom clearance")
                let expected = 255 * 0.55 * (state.isDimmed ? 0.5 : 1)
                XCTAssertEqual(maxFrameAlpha, expected, accuracy: 6, "\(scale)x \(state): frame opacity")
            }
            XCTAssertEqual(frameRows.count, 1, "\(scale)x dark=\(dark): frame height changes with the state \(frameRows)")
        } }
    }

    func testRoundedFrameIsNeutralAndTheBoltStaysGreen() throws {
        for dark in [false, true] {
            let image = try pixels(MenuBarSystemImage.render(display(.battery, .percent(82), charging: true), dark: dark, scale: 2, frame: .rounded))
            XCTAssertGreaterThan(image.count(isGreen), 0)
            // Frame pixels are grey (black or white at 55 %): no colour except the bolt.
            XCTAssertEqual(image.count { $0.a > 60 && (abs($0.r - $0.g) > 40 || abs($0.g - $0.b) > 40) && !($0.g > $0.r && $0.g > $0.b) }, 0)
        }
    }

    /// AGY's number is 0.5 pt higher (1 px at 2×); its name, Codex and Claude are pixel-identical to before.
    func testAGYNumberIsLiftedAndNothingElseMoves() throws {
        XCTAssertEqual(MenuBarNumericImage.Layout.standard.singleNumberLift, 0.5)
        XCTAssertEqual(MenuBarNumericImage.Layout.first.singleNumberLift, 0)
        let items = [NumericGaugeItem(provider: .codex, primary: 11, secondary: 42, hasSecondarySlot: true, stale: false),
                     NumericGaugeItem(provider: .claude, primary: 43, secondary: 38, hasSecondarySlot: true, stale: false),
                     NumericGaugeItem(provider: .antigravity, primary: 51, secondary: nil, hasSecondarySlot: false, stale: false)]
        let layout = MenuBarNumericImage.Layout.standard
        let columns = items.map { MenuBarNumericImage.column($0, layout: layout, color: .black) }
        // Only AGY's digit run moved, by exactly 0.5 pt.
        for (index, column) in columns.enumerated() {
            let before = MenuBarNumericImage.column(items[index], layout: aiWithoutLift, color: .black)
            for (run, old) in zip(column.runs, before.runs) {
                let isAGYDigits = index == 2 && run.line === column.runs.first?.line
                XCTAssertEqual(run.baseline, old.baseline - (isAGYDigits ? 0.5 : 0), accuracy: 0.0001)
                XCTAssertEqual(run.x, old.x, accuracy: 0.0001)
            }
            XCTAssertEqual(column.width, before.width)
        }
        XCTAssertEqual(MenuBarNumericImage.size(items), MenuBarNumericImage.size(items, layout: aiWithoutLift))
        for scale in [2, 3] { for dark in [false, true] {
            let now = try pixels(MenuBarNumericImage.render(items, dark: dark, scale: scale))
            let old = try pixels(MenuBarNumericImage.render(items, dark: dark, scale: scale, layout: aiWithoutLift))
            let agyStart = Int((MenuBarNumericImage.sidePadding + columns[0].width + columns[1].width + 2 * layout.columnSpacing) * CGFloat(scale))
            let nameRow = Int((MenuBarNumericImage.vertical(layout).nameBaseline - 5.5) * CGFloat(scale))
            var changedOutsideAGYDigits = 0
            for y in 0..<now.height { for x in 0..<now.width where x < agyStart - 2 || y >= nameRow {
                let i = (y * now.width + x) * 4
                if now.data[i..<i + 4] != old.data[i..<i + 4] { changedOutsideAGYDigits += 1 }
            } }
            XCTAssertEqual(changedOutsideAGYDigits, 0, "\(scale)x dark=\(dark): Codex, Claude or the AGY name changed")
            func digitTop(_ p: Pixels) -> Int? { (0..<nameRow).first { y in (agyStart..<p.width).contains { p.rgba($0, y).a > 128 } } }
            XCTAssertEqual(try XCTUnwrap(digitTop(old)) - (try XCTUnwrap(digitTop(now))), scale == 2 ? 1 : 2, accuracy: 1, "\(scale)x: AGY digits higher")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(now.inkBounds).minY, 1, "\(scale)x: AGY not clipped at the top")
        } }
    }

    // MARK: 12. Number–% gap 1.7 pt and frame height 17.5 pt (6-3 final tuning)

    /// The system gap is its own 1.7 pt; the AI keeps 1.2 pt around "/". In the layout the `%` run starts exactly
    /// 1.7 pt after the digits' ink, for both styles, and no image grows.
    func testPercentGapIsSystemOnlyAndKeepsWidths() {
        XCTAssertEqual(MenuBarSystemImage.percentGap, 1.7)
        XCTAssertEqual(MenuBarNumericImage.Layout.standard.separatorGap, 1.2, "AI gap unchanged")
        for style in SystemWidgetLayout.allCases { for value in [10, 24, 82, 99, 100] {
            let column = MenuBarSystemImage.column(display(.cpu, .percent(value)))
            let width = MenuBarSystemImage.fixedWidth(name: "CPU", value: .percent(value))
            let runs = MenuBarSystemImage.runs(column, width: width, dark: false, style: style).runs
            let digitInk = MenuBarNumericImage.ink(runs[0].line), percentInk = MenuBarNumericImage.ink(runs[1].line)
            XCTAssertEqual((runs[1].x + percentInk.minX) - (runs[0].x + digitInk.maxX), 1.7, accuracy: 0.0001, "\(style) \(value)%")
            XCTAssertEqual(runs[0].baseline, runs[1].baseline, "\(style) \(value)%: same baseline")
            // Number and % centred as one group.
            XCTAssertEqual(((runs[0].x + digitInk.minX) + (runs[1].x + percentInk.maxX)) / 2, width / 2, accuracy: 0.0001)
        } }
        // Image widths as before the change (whole-point rounding absorbs the 0.5 pt).
        for widget in twoRow {
            XCTAssertEqual(MenuBarSystemImage.size(display(widget, .percent(24))).width, 25)
            XCTAssertEqual(MenuBarSystemImage.size(display(widget, .percent(100))).width, 31)
        }
        XCTAssertEqual(MenuBarSystemImage.size(display(.battery, .percent(82))).width, 25)
        XCTAssertEqual(MenuBarSystemImage.size(display(.battery, .percent(82), charging: true)).width, 33)
        XCTAssertEqual(MenuBarSystemImage.size(display(.battery, .percent(100), charging: true), frame: .rounded).width, 45)
    }

    /// In pixels at 2×, two-digit values now show at least two fully clear columns between number and `%`
    /// (one before), and Battery minimal and rounded draw the same gap.
    func testPercentGapInPixels() throws {
        func clearColumns(_ image: Pixels, rows: Range<Int>, columns: Range<Int>? = nil) -> Int {
            func ink(_ x: Int) -> Bool { rows.contains { image.rgba(x, $0).a > 0 } }
            let xs = columns ?? 0..<image.width
            let right = xs.last(where: ink)!
            var percentLeft = right; while percentLeft > xs.lowerBound, ink(percentLeft - 1) { percentLeft -= 1 }
            var digitRight = percentLeft - 1; while digitRight > 0, !ink(digitRight) { digitRight -= 1 }
            return percentLeft - digitRight - 1
        }
        for value in [24, 82, 99] {
            let cpu = try styled(.cpu, .percent(value), .split)
            let top = Int((MenuBarSystemImage.baselines(.split).name + 1) * CGFloat(scale))
            XCTAssertGreaterThanOrEqual(clearColumns(cpu, rows: top..<cpu.height), 2, "\(value)%")
            let minimal = try pixels(MenuBarSystemImage.render(display(.battery, .percent(value)), dark: false, scale: scale))
            let rounded = try pixels(MenuBarSystemImage.render(display(.battery, .percent(value)), dark: false, scale: scale, frame: .rounded))
            // In the rounded image look left of the frame's right stroke (the rightmost run of ink columns).
            // Middle rows only: there the frame is just its two vertical strokes, clear of the content by 2.25 pt.
            let middle = (rounded.height * 2 / 5)..<(rounded.height * 3 / 5)
            func anyInk(_ x: Int) -> Bool { middle.contains { rounded.rgba(x, $0).a > 0 } }
            var strokeLeft = try XCTUnwrap((0..<rounded.width).last(where: anyInk))
            while strokeLeft > 0, anyInk(strokeLeft - 1) { strokeLeft -= 1 }
            XCTAssertGreaterThan(strokeLeft, 3 * scale)
            let inside = (3 * scale)..<max(3 * scale + 1, strokeLeft)
            XCTAssertEqual(clearColumns(minimal, rows: middle), clearColumns(rounded, rows: middle, columns: inside),
                           "\(value)%: same gap with the frame")
            XCTAssertGreaterThanOrEqual(clearColumns(minimal, rows: middle), 2, "\(value)%: battery gap")
        }
    }

    /// 17.5 pt frame: stroke from 1.875 to 20.125 pt (outer edges), centred, same left/right as before.
    func testFrameHeightIsSeventeenAndAHalf() throws {
        for scale in [2, 3] { for dark in [false, true] { for state in batteryStates {
            let minimal = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale))
            let rounded = try pixels(MenuBarSystemImage.render(state, dark: dark, scale: scale, frame: .rounded))
            var top = Int.max, bottom = -1
            for y in 0..<rounded.height { for x in 0..<rounded.width where rounded.rgba(x, y).a > 0 {
                let mx = x - 3 * scale
                if mx >= 0 && mx < minimal.width && minimal.rgba(mx, y).a > 0 { continue }
                top = min(top, y); bottom = max(bottom, y)
            } }
            let s = Double(scale)
            XCTAssertEqual(Double(top) / s, 1.875, accuracy: 1 / s, "\(scale)x \(state): top")
            XCTAssertEqual(Double(bottom + 1) / s, 20.125, accuracy: 1 / s, "\(scale)x \(state): bottom")
            XCTAssertEqual(Double(top + bottom + 1) / 2 / s, 11, accuracy: 0.5 / s + 0.01, "\(scale)x \(state): centred")
            XCTAssertGreaterThanOrEqual(top, 1); XCTAssertLessThanOrEqual(bottom, rounded.height - 2)
        } } }
    }
}
