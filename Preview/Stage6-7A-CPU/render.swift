// Offline visual comparison only. No Tokenly app process, settings, Store, or live measurement is touched.
// The illustrative numbers and graph points are identical in every variant and are NOT measured data.
import AppKit
import SwiftUI

private enum Variant: String, CaseIterable { case current, flat, soft }

private struct PreviewCPU: View {
    let variant: Variant
    let dark: Bool
    private let teal = Color(red: 0.62, green: 0.93, blue: 0.86)
    private let darkBackground = Color(red: 0.125, green: 0.135, blue: 0.155)
    private let lightBackground = Color(red: 0.965, green: 0.968, blue: 0.976)
    private var accent: Color { dark ? teal : Color(red: 0.08, green: 0.58, blue: 0.50) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            core.padding(.horizontal, 8).padding(.top, 8)
            topFive.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .frame(width: 340, height: 345, alignment: .top)
        .background(variant == .current ? (dark ? Color(red: 0.18, green: 0.19, blue: 0.21) : Color(red: 0.93, green: 0.94, blue: 0.95)) : (dark ? darkBackground : lightBackground))
        .foregroundStyle(dark ? Color.white : Color(red: 0.14, green: 0.16, blue: 0.19))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var core: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("CPU").font(.system(size: 13, weight: .semibold))
                    Text("보통").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(accent.opacity(dark ? 0.16 : 0.14), in: Capsule())
                    Spacer()
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("24").font(.system(size: variant == .current ? 44 : 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("%").font(.system(size: variant == .current ? 20 : 21, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) { Text("사용자").foregroundStyle(.secondary); Text("17%").fontWeight(.semibold) }
                        HStack(spacing: 6) { Text("시스템").foregroundStyle(.secondary); Text("7%").fontWeight(.semibold) }
                    }.font(.system(size: 11).monospacedDigit())
                }
            }
            .padding(.horizontal, 14).padding(.top, 11)
            StaticAurora(dark: dark).frame(height: 84).padding(.top, 6)
        }
        .background(coreBackground)
        .clipShape(variant == .current ? RoundedRectangle(cornerRadius: 12, style: .continuous) : RoundedRectangle(cornerRadius: 0))
        .overlay {
            if variant == .current {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(dark ? 0.10 : 0.55), lineWidth: 0.75)
            }
        }
    }

    @ViewBuilder private var coreBackground: some View {
        switch variant {
        case .current:
            LinearGradient(colors: [accent.opacity(dark ? 0.05 : 0.07), .clear], startPoint: .top, endPoint: .bottom)
        case .flat:
            Color.clear
        case .soft:
            LinearGradient(colors: [Color.white.opacity(dark ? 0.035 : 0.38), Color.white.opacity(0.01)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var topFive: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("프로세스 TOP 5").font(.system(size: 12, weight: .semibold))
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(Array(zip(["Safari", "Tokenly", "WindowServer", "Xcode", "Finder"],
                              ["41.2%", "18.4%", "12.1%", "8.7%", "3.5%"])).indices, id: \.self) { i in
                let names = ["Safari", "Tokenly", "WindowServer", "Xcode", "Finder"]
                let values = ["41.2%", "18.4%", "12.1%", "8.7%", "3.5%"]
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.22)).frame(width: 18, height: 18)
                        .overlay(Text(String(names[i].prefix(1))).font(.system(size: 9, weight: .medium)))
                    Text(names[i]).font(.system(size: 12))
                    Spacer(minLength: 8)
                    Text(values[i]).font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
        }
    }
}

private struct StaticAurora: View {
    let dark: Bool
    // Illustrative 60-second shape; never represented as a real CPU reading.
    private let levels: [CGFloat] = [21, 23, 19, 28, 25, 31, 27, 34, 29, 32, 26, 22, 29, 25, 24]
    var body: some View {
        GeometryReader { geometry in
            let points = levels.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) / CGFloat(levels.count - 1) * (geometry.size.width - 7),
                        y: geometry.size.height - value / 100 * (geometry.size.height - 3))
            }
            let line = Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            let area = Path { path in
                path.addPath(line)
                if let first = points.first, let last = points.last {
                    path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: first.x, y: geometry.size.height))
                    path.closeSubpath()
                }
            }
            let gradient = LinearGradient(colors: [Color(red: 0.78, green: 0.50, blue: 0.98),
                                                   Color(red: 0.38, green: 0.62, blue: 0.98),
                                                   dark ? Color(red: 0.25, green: 0.85, blue: 0.72) : Color(red: 0.05, green: 0.62, blue: 0.52)],
                                          startPoint: .top, endPoint: .bottom)
            ZStack(alignment: .topLeading) {
                gradient.mask(area.fill(.black)).opacity(dark ? 0.30 : 0.22).blur(radius: 10)
                gradient.mask(area.fill(LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)))
                gradient.mask(line.stroke(.black, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)))
                if let last = points.last {
                    Circle().fill(Color(red: 0.25, green: 0.85, blue: 0.72).opacity(0.25)).frame(width: 11, height: 11).position(last)
                    Circle().fill(Color(red: 0.25, green: 0.85, blue: 0.72)).frame(width: 5, height: 5).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

@main struct Render {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [true, false] {
            for variant in Variant.allCases {
                let view = PreviewCPU(variant: variant, dark: dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "PreviewRender", code: 1)
                }
                let name = "cpu-\(variant.rawValue)-\(dark ? "dark" : "light").png"
                try data.write(to: output.appendingPathComponent(name))
                print("\(name): \(image.width)x\(image.height) px")
            }
        }
    }
}
