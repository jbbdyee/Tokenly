// README images for the three menu bar styles, drawn by the app's own renderers on light/dark bars.
// These are renders, not screen captures. Run ./run.sh; output goes to ../../Doc/images.
import AppKit
import SwiftUI

func bar<V: View>(_ content: V, dark: Bool) -> some View {
    HStack(spacing: 14) {
        content
        Text("12:34").font(.system(size: 13)).foregroundStyle(dark ? Color.white : .black)
    }
    .padding(.horizontal, 12).frame(height: 24)
    .background(dark ? Color(white: 0.13) : Color(white: 0.93))
}

@MainActor func save<V: View>(_ v: V, _ name: String) {
    let r = ImageRenderer(content: v); r.scale = 2
    try! NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
    print("wrote", name)
}

@main struct Main { @MainActor static func main() {
    let numeric = [NumericGaugeItem(provider: .codex, primary: 97, secondary: 89, hasSecondarySlot: true, stale: false),
                   NumericGaugeItem(provider: .claude, primary: 28, secondary: 91, hasSecondarySlot: true, stale: false),
                   NumericGaugeItem(provider: .antigravity, primary: 54, secondary: nil, hasSecondarySlot: false, stale: false)]
    let bears = [MenuBarBearItem(percent: 54, name: "Codex", service: "codex"),
                 MenuBarBearItem(percent: 89, name: "Claude", service: "claude"),
                 MenuBarBearItem(percent: 100, name: "AGY", service: "antigravity")]
    let compact = MenuBarPresentation.text(style: .compact, snapshot: UsageSnapshot(providerName: "Codex", windows: [
        UsageWindow(kind: .fiveHours, usedPercent: 3, resetsAt: nil), UsageWindow(kind: .sevenDays, usedPercent: 11, resetsAt: nil)
    ], fetchedAt: Date()), isRefreshing: false, hasError: false)
    for (name, view) in [
        ("menubar-numeric.png", AnyView(VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { d in bar(Image(nsImage: MenuBarNumericImage.make(numeric, dark: d)!), dark: d) } })),
        ("menubar-compact.png", AnyView(VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { d in bar(Text(compact).monospacedDigit().foregroundStyle(d ? Color.white : .black), dark: d) } })),
        ("menubar-bear.png", AnyView(VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { d in bar(Image(nsImage: MenuBarBearImage.make(bears, dark: d)!), dark: d) } })),
    ] { save(view, name) }
}}
