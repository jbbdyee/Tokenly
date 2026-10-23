// The app's menu bar heart row before the 2026-10-23 redesign (name under the heart, "%" digits,
// 8pt spacing). Kept only so the earlier preview studies (HeartLegibility, HeartStyles, Heart3D/run.sh)
// still compile; the app now uses MenuBarGaugeRow.
import AppKit
import SwiftUI

/// One menu bar heart: remaining percent inside, short service name underneath.
/// Sized for the 22pt status item height; tune the constants here.
struct MenuBarHeart: View {
    let percent: Double
    let name: String
    let palette: HeartPalette

    static let width: CGFloat = 18
    static let percentFontSize: CGFloat = 6.5
    // ImageRenderer ignores minimumScaleFactor here, so "100%" gets an explicit smaller size.
    static let wideFontSize: CGFloat = 5.4
    static let nameFontSize: CGFloat = 6
    /// Vertical space between the heart frame and the name's line box; negative overlaps the box's empty top.
    static let nameSpacing: CGFloat = -0.25
    /// Empty space trimmed under the name. Short names have no descenders; 0.3pt of the 1.9pt blank stays.
    static let nameBottomTrim: CGFloat = 1.6

    var body: some View {
        let text = "\(Int(min(max(percent, 0), 100).rounded()))%"
        VStack(spacing: Self.nameSpacing) {
            JellyHeart(fraction: percent / 100, palette: palette, width: Self.width) {
                Text(text)
                    .font(.system(size: text.count > 3 ? Self.wideFontSize : Self.percentFontSize,
                                  weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.2)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .shadow(color: .white.opacity(0.9), radius: 0.4)
                    .offset(y: -0.5)
            }
            // Service-tinted mid-tone stays visible on both light and dark menu bars in a non-template image.
            Text(name)
                .font(.system(size: Self.nameFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(palette.rim)
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, -Self.nameBottomTrim)
        }
    }
}

struct MenuBarHeartItem {
    let percent: Double
    let name: String
    let palette: HeartPalette
}

struct MenuBarHeartRow: View {
    let hearts: [MenuBarHeartItem]
    static let heartSpacing: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: Self.heartSpacing) {
            ForEach(hearts.indices, id: \.self) { index in
                MenuBarHeart(percent: hearts[index].percent, name: hearts[index].name,
                             palette: hearts[index].palette)
            }
        }
        .padding(.horizontal, 1)
    }
}

enum MenuBarHeartImage {
    /// MenuBarExtra labels only draw plain Text/Image, so the SwiftUI hearts are flattened into a bitmap.
    /// At least 2x keeps the tiny digits sharp on Retina menu bars.
    @MainActor
    static func make(_ hearts: [MenuBarHeartItem]) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarHeartRow(hearts: hearts))
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
