import AppKit
import SwiftUI

// Colors for one jelly heart. Tweak hues here; geometry and lighting live in JellyHeart.
struct HeartPalette {
    let fillTop: Color
    let fillBottom: Color
    let emptyTop: Color
    let emptyBottom: Color
    let rim: Color
    let ink: Color

    static let codex = HeartPalette(hex: 0xFF8A80, top: 0xFFB3A7, deep: 0xE25A55, ink: 0x8E2B2B)
    static let claude = HeartPalette(hex: 0xB79CF2, top: 0xD7C6FF, deep: 0x7E5CCB, ink: 0x45307A)
    static let antigravity = HeartPalette(hex: 0x7CC6F2, top: 0xB5E2FF, deep: 0x3F93C9, ink: 0x1E5378)
    // Neutral look for stale data so an old value never reads as the current one.
    static let stale = HeartPalette(hex: 0xB4B4BA, top: 0xD4D4D9, deep: 0x84848C, ink: 0x4A4A50)

    private init(hex: UInt32, top: UInt32, deep: UInt32, ink: UInt32) {
        fillTop = Color(hex: hex)
        fillBottom = Color(hex: deep)
        // Near-white empty jelly keeps the fill level readable on light and dark menu bars.
        emptyTop = Color(hex: 0xFFFFFF).opacity(0.92)
        emptyBottom = Color(hex: top).opacity(0.85)
        rim = Color(hex: deep)
        self.ink = Color(hex: ink)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A plump heart that fills the whole rect: lobes touch the top edge, the rounded tip touches the bottom.
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: pt(0.5, 1.0))
        path.addCurve(to: pt(0.0, 0.34), control1: pt(0.36, 0.98), control2: pt(0.0, 0.66))
        path.addCurve(to: pt(0.5, 0.17), control1: pt(0.0, 0.0), control2: pt(0.40, -0.05))
        path.addCurve(to: pt(1.0, 0.34), control1: pt(0.60, -0.05), control2: pt(1.0, 0.0))
        path.addCurve(to: pt(0.5, 1.0), control1: pt(1.0, 0.66), control2: pt(0.64, 0.98))
        path.closeSubpath()
        return path
    }
}

/// Jelly-style heart gauge. `fraction` is 0...1 filled from the bottom; nil draws an empty heart with "?".
struct JellyHeart<Label: View>: View {
    let fraction: Double?
    let palette: HeartPalette
    let width: CGFloat
    @ViewBuilder var label: () -> Label

    static var aspect: CGFloat { 0.88 }

    var body: some View {
        let height = width * Self.aspect
        let level = CGFloat(min(max(fraction ?? 0, 0), 1))
        let rimWidth = max(1, width * 0.055)
        ZStack {
            HeartShape().fill(LinearGradient(colors: [palette.emptyTop, palette.emptyBottom],
                                             startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [palette.fillTop, palette.fillBottom], startPoint: .top, endPoint: .bottom)
                .frame(height: height * level)
                .overlay(alignment: .top) {
                    // Liquid surface line; hidden when empty or full.
                    if level > 0.02 && level < 0.98 {
                        Rectangle().fill(.white.opacity(0.6)).frame(height: max(0.75, width * 0.025))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(HeartShape())
            // Soft inner shade along the lower edge gives the jelly some volume.
            HeartShape()
                .stroke(palette.rim.opacity(0.35), lineWidth: rimWidth * 2.2)
                .blur(radius: rimWidth)
                .clipShape(HeartShape())
            HeartShape().stroke(palette.rim, lineWidth: rimWidth)
            Ellipse()
                .fill(.white.opacity(0.75))
                .frame(width: width * 0.24, height: width * 0.13)
                .rotationEffect(.degrees(-32))
                .offset(x: -width * 0.21, y: -height * 0.19)
            Circle()
                .fill(.white.opacity(0.65))
                .frame(width: width * 0.07)
                .offset(x: -width * 0.06, y: -height * 0.29)
            label()
        }
        .frame(width: width, height: height)
        .shadow(color: palette.rim.opacity(0.35), radius: width * 0.035, y: width * 0.03)
    }
}

extension JellyHeart where Label == EmptyView {
    init(fraction: Double?, palette: HeartPalette, width: CGFloat) {
        self.init(fraction: fraction, palette: palette, width: width) { EmptyView() }
    }
}
