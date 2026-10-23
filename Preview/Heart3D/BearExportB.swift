// Exports the option-B bear assets for the app: 21pt-wide frame, ears ×1.05 (face unchanged),
// empty/full layers per service at @2x and @3x, plus a manifest with the per-scale layout anchors.
// Run ./run-bear-b.sh; output goes to ./assets-b (copy into src/Tokenly/Resources/BearGauge to ship).
import AppKit
import CoreImage
import SwiftUI

let frameWidth: CGFloat = 21
let earScale: CGFloat = 1.05
let nameHalfHeight: CGFloat = 4.38 / 2   // 6pt heavy rounded cap height / 2
let nameKnockout: CGFloat = 0.75         // 1.5px at 2x

struct FrameInfo: Codable {
    let width: Double, height: Double
    let fillTop: Int, fillBottom: Int
    /// Face centre above the name, in points from the frame's top-left.
    let numberCenterY: Double
}

struct ManifestB: Codable {
    let version: Int
    let earScale: Double
    let frames: [String: FrameInfo]
    let numberCoveredAt: Double
    let services: [String]
    let layers: [String]
}

@main
struct ExportB {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("assets-b")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = BearRenderer(earScale: earScale)
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        var frames: [String: FrameInfo] = [:]
        var coveredAt = 0.7
        for scale in [2, 3] {
            let px = Int(frameWidth) * scale
            var rows: (Int, Int) = (0, 0)
            var height = 0
            for color in BearColor.allCases {
                for filled in [false, true] {
                    let source = renderer.render(color: color, filled: filled, pixelWidth: px * 8)
                    let s = CGFloat(px) / CGFloat(source.width)
                    height = Int((CGFloat(source.height) * s).rounded())
                    let image = ci.createCGImage(
                        CIImage(cgImage: source).applyingFilter("CILanczosScaleTransform",
                                                                parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1]),
                        from: CGRect(x: 0, y: 0, width: px, height: height),
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
                    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                        .write(to: out.appendingPathComponent("bear-\(color.rawValue)-\(filled ? "full" : "empty")@\(scale)x.png"))
                    if color == .codex && !filled { rows = silhouette(image) }
                }
            }
            let earTop = CGFloat(rows.0) / CGFloat(scale), chin = CGFloat(rows.1) / CGFloat(scale)
            // Outline units → points: the face superellipse starts at unit 0.105, the scaled ears at 0.15 − 0.085·s.
            let pointsPerUnit = frameWidth / 1.04
            let faceTop = earTop + (0.105 - (0.15 - 0.085 * earScale)) * pointsPerUnit
            let nameTop = chin - nameHalfHeight - nameKnockout
            let center = (faceTop + nameTop) / 2
            frames["\(scale)"] = FrameInfo(width: Double(frameWidth), height: Double(height) / Double(scale),
                                           fillTop: rows.0, fillBottom: rows.1, numberCenterY: Double(center))
            if scale == 2 {
                // Fill level that covers the top of a 6.9pt-high digit run centred there.
                coveredAt = Double((chin - (center - 3.45)) / (chin - earTop))
            }
            print("@\(scale)x \(px)x\(height)px silhouette rows \(rows.0)…\(rows.1), face top \(faceTop), name top \(nameTop), number centre \(center)")
        }
        let manifest = ManifestB(version: 2, earScale: Double(earScale), frames: frames,
                                 numberCoveredAt: (coveredAt * 100).rounded() / 100,
                                 services: BearColor.allCases.map(\.rawValue), layers: ["empty", "full"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try! encoder.encode(manifest).write(to: out.appendingPathComponent("bear-assets.json"))
        print("numberCoveredAt", manifest.numberCoveredAt)
    }

    static func silhouette(_ image: CGImage) -> (Int, Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var top = image.height, bottom = 0
        for y in 0..<image.height where (0..<image.width).contains(where: { bytes[(y * image.width + $0) * 4 + 3] > 127 }) {
            top = min(top, y); bottom = max(bottom, y + 1)
        }
        return (top, bottom)
    }
}
