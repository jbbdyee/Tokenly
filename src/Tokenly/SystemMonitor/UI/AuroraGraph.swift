import SwiftUI

/// Monotone cubic interpolation (Fritsch–Carlson) for the CPU popover graph. The curve passes through every
/// measured point and, between two neighbouring points, never goes above the higher or below the lower of them:
/// no peak or dip that was not measured.
enum AuroraCurve {
    struct Segment: Equatable {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
    }

    /// Cubic pieces joining `points` in order. Points must have increasing x. Fewer than two points: no pieces.
    static func monotoneCubic(_ points: [CGPoint]) -> [Segment] {
        let n = points.count
        guard n > 1 else { return [] }
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<n - 1 { slopes[i] = (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x) }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<n - 1 { tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2 }
        for i in 0..<n - 1 where slopes[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<n - 1 where slopes[i] != 0 {
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i], s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                tangents[i] = t * a * slopes[i]
                tangents[i + 1] = t * b * slopes[i]
            }
        }
        return (0..<n - 1).map { i in
            let h = points[i + 1].x - points[i].x
            return Segment(start: points[i],
                           control1: CGPoint(x: points[i].x + h / 3, y: points[i].y + tangents[i] * h / 3),
                           control2: CGPoint(x: points[i + 1].x - h / 3, y: points[i + 1].y - tangents[i + 1] * h / 3),
                           end: points[i + 1])
        }
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in monotoneCubic(points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return path
    }
}

/// The RAM popover's mint · pastel blue · lavender (its composition bar, `RAMPopoverView.appColor` etc.), shared so
/// other screens can match it (UI colour harmony, 2026-10-29). Dark mode uses the RAM hex values as they are; light
/// mode uses deeper shades of the same hues that already exist in the app, so lines and text stay readable.
enum HarmonyPalette {
    static func hex(_ v: UInt32) -> AuroraPalette.RGB {
        AuroraPalette.RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
    /// RAM "앱 메모리" #A5E2D7; light: the former CPU accent #149480.
    static func mint(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xA5E2D7 : 0x149480) }
    /// RAM "와이어드" #A8CDF4; light: the GPU light-mode blue #3A7BC8.
    static func blue(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xA8CDF4 : 0x3A7BC8) }
    /// RAM "압축" #C5B3EE; light: the GPU light-mode lavender #8A63C9.
    static func lavender(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xC5B3EE : 0x8A63C9) }
    /// Text on a mint badge: RAM's normal-pressure badge colours (#A5E2D7 dark, #1F6B5E light).
    static func mintText(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xA5E2D7 : 0x1F6B5E) }
}

/// The B1 "Aurora Flow" colours (approved 2026-10-28): colour is a function of height only (0 % teal, 50 % blue,
/// 100 % violet), so the same value always has the same colour. Violet means "high", never an error.
enum AuroraPalette {
    struct RGB: Equatable {
        let r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    /// `standard` is the approved B1 palette (CPU, RAM). `gpu` (6-4d) keeps the same height rule in baby blue →
    /// periwinkle → lavender: the given hex in dark mode, deeper versions of the same hues in light mode so the line
    /// stays visible on a light background.
    /// `cpu` (UI colour harmony, 2026-10-29): RAM's lavender at the bottom, pastel blue in the middle, mint at the
    /// top, so the usual 10–20 % CPU line reads lavender. Same height rule; only the colours differ from `standard`.
    enum Scheme { case standard, gpu, cpu }

    static func stops(dark: Bool, scheme: Scheme) -> [(value: Double, rgb: RGB)] {
        if scheme == .cpu {
            return [(0, HarmonyPalette.lavender(dark: dark)), (50, HarmonyPalette.blue(dark: dark)), (100, HarmonyPalette.mint(dark: dark))]
        }
        guard scheme == .gpu else { return stops(dark: dark) }
        func hex(_ v: UInt32) -> RGB { RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255) }
        return dark ? [(0, hex(0xA8CDF4)), (50, hex(0xA9B6F0)), (100, hex(0xC5B3EE))]
                    : [(0, hex(0x3A7BC8)), (50, hex(0x5B6BD0)), (100, hex(0x8A63C9))]
    }

    static func stops(dark: Bool) -> [(value: Double, rgb: RGB)] {
        dark ? [(0, RGB(r: 0.25, g: 0.85, b: 0.72)), (50, RGB(r: 0.38, g: 0.62, b: 0.98)), (100, RGB(r: 0.78, g: 0.50, b: 0.98))]
             : [(0, RGB(r: 0.05, g: 0.62, b: 0.52)), (50, RGB(r: 0.18, g: 0.42, b: 0.88)), (100, RGB(r: 0.55, g: 0.28, b: 0.85))]
    }

    /// Colour for a value in percent (clamped to 0...100), linearly between the stops.
    static func rgb(for value: Double, dark: Bool, scheme: Scheme = .standard) -> RGB {
        let stops = stops(dark: dark, scheme: scheme)
        let v = min(max(value.isFinite ? value : 0, 0), 100)
        let upper = v <= stops[1].value ? 1 : 2
        let a = stops[upper - 1], b = stops[upper]
        let t = (v - a.value) / (b.value - a.value)
        return RGB(r: a.rgb.r + (b.rgb.r - a.rgb.r) * t, g: a.rgb.g + (b.rgb.g - a.rgb.g) * t, b: a.rgb.b + (b.rgb.b - a.rgb.b) * t)
    }

    /// Glow (blurred copy of the area) opacity and blur, crisp area fill opacity at the top, line width.
    static func glowOpacity(dark: Bool) -> Double { dark ? 0.30 : 0.22 }
    static let glowBlur: CGFloat = 10
    static let fillTopOpacity: Double = 0.28
    static let lineWidth: CGFloat = 1.25
}

/// Where the graph puts things: fixed 0–100 % over the height below a 3 pt top inset (so 100 % and its glow are not
/// clipped), the last 60 s over the width minus 7 pt kept free on the right for the current point. Pure; tested.
struct AuroraGraphLayout: Equatable {
    static let topInset: CGFloat = 3
    static let rightInset: CGFloat = 7

    /// Lines (one per unbroken run of measured points, M1 policy) in view coordinates.
    let segments: [[CGPoint]]
    /// The newest measured point, if it is the newest point of the history (not followed by a gap).
    let current: CGPoint?
    let currentValue: Double?

    init(history: SystemMetricHistory, size: CGSize) {
        let width = max(0, size.width - Self.rightInset), height = size.height
        guard let end = history.points.last?.date else {
            segments = []; current = nil; currentValue = nil
            return
        }
        func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(end) + SystemMetricHistory.window) / CGFloat(SystemMetricHistory.window) * width }
        func y(_ value: Double) -> CGFloat { Self.y(value, height: height) }
        let parts = SystemWidgetPresentation.segments(history)
        segments = parts.map { $0.points.map { CGPoint(x: x($0.date), y: y($0.value)) } }
        if let last = parts.last?.points.last, last.date == end {
            current = CGPoint(x: x(last.date), y: y(last.value))
            currentValue = last.value
        } else {
            current = nil; currentValue = nil
        }
    }

    static func y(_ value: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(min(max(value, 0), 100)) / 100 * (height - topInset)
    }
}

/// Horizontal alpha ramp for flat-layout graphs' area and glow. The graph line is never masked by this ramp.
enum AuroraAreaEdgeFade {
    static let edgeFraction = 0.055

    static func opacity(at fraction: Double) -> Double {
        let x = min(max(fraction, 0), 1)
        return min(1, x / edgeFraction, (1 - x) / edgeFraction)
    }

    static var mask: LinearGradient {
        LinearGradient(stops: [0, edgeFraction, 1 - edgeFraction, 1].map {
            .init(color: .white.opacity(opacity(at: $0)), location: $0)
        }, startPoint: .leading, endPoint: .trailing)
    }
}

/// CPU popover graph, design B1 "Aurora Flow". One data line; every effect is that line or the area under it
/// (no second curve, point or label). Redrawn only when the history changes; no animation of its own.
struct AuroraGraph: View {
    let history: SystemMetricHistory
    /// Colour scheme of the height gradient; CPU and RAM keep `standard`.
    var palette: AuroraPalette.Scheme = .standard
    /// Flat popover layouts only. Softens the glow and area at the graph bounds without erasing measured line endpoints.
    var fadesAreaEdges = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let dark = colorScheme == .dark
            let layout = AuroraGraphLayout(history: history, size: geometry.size)
            let gradient = heightGradient(dark: dark, height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                if layout.segments.isEmpty {
                    Text("측정 데이터 없음").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, points in
                    let line = AuroraCurve.path(points)
                    let area = Self.area(line, points, bottom: geometry.size.height)
                    horizontalAreaFade(gradient.mask(area.fill(Color.black))
                        .opacity(AuroraPalette.glowOpacity(dark: dark)).blur(radius: AuroraPalette.glowBlur))
                    horizontalAreaFade(gradient.mask(area.fill(LinearGradient(colors: [.black.opacity(AuroraPalette.fillTopOpacity), .black.opacity(0)],
                                                                              startPoint: .top, endPoint: .bottom))))
                    gradient.mask(line.stroke(Color.black, style: StrokeStyle(lineWidth: AuroraPalette.lineWidth, lineCap: .round, lineJoin: .round)))
                    if points.count == 1, let point = points.first {
                        Circle().fill(AuroraPalette.rgb(for: value(atY: point.y, height: geometry.size.height), dark: dark, scheme: palette).color)
                            .frame(width: 3, height: 3).position(point)
                    }
                }
                if let current = layout.current, let value = layout.currentValue {
                    let color = AuroraPalette.rgb(for: value, dark: dark, scheme: palette).color
                    ZStack {
                        Circle().fill(color.opacity(0.25)).frame(width: 11, height: 11)
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                    .position(current)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The graph line and current-point marker stay outside this mask. The narrow fade removes hard vertical
    /// area/glow edges while keeping the sampled values at x=0 and at the newest point visible.
    @ViewBuilder private func horizontalAreaFade<Content: View>(_ content: Content) -> some View {
        if fadesAreaEdges {
            content.mask(AuroraAreaEdgeFade.mask)
        } else {
            content
        }
    }

    /// The palette laid over the graph so a point's colour is the colour of its value (0 % at the bottom edge,
    /// 100 % at the top inset).
    private func heightGradient(dark: Bool, height: CGFloat) -> LinearGradient {
        let top = height > 0 ? AuroraGraphLayout.topInset / height : 0
        return LinearGradient(stops: AuroraPalette.stops(dark: dark, scheme: palette).map { .init(color: $0.rgb.color, location: $0.value / 100) },
                              startPoint: UnitPoint(x: 0.5, y: 1), endPoint: UnitPoint(x: 0.5, y: top))
    }

    private func value(atY y: CGFloat, height: CGFloat) -> Double {
        guard height > AuroraGraphLayout.topInset else { return 0 }
        return Double((height - y) / (height - AuroraGraphLayout.topInset) * 100)
    }

    private static func area(_ line: Path, _ points: [CGPoint], bottom: CGFloat) -> Path {
        var area = line
        guard let first = points.first, let last = points.last else { return area }
        area.addLine(to: CGPoint(x: last.x, y: bottom))
        area.addLine(to: CGPoint(x: first.x, y: bottom))
        area.closeSubpath()
        return area
    }
}
