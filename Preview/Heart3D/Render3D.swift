// SceneKit physically based rendering of the inflated heart, for the soft 3D and glass jelly styles.
import AppKit
import SceneKit
import SwiftUI

func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
}

/// Confirmed service colours; the stale grey stays neutral.
enum HeartColor: String, CaseIterable {
    case codex, claude, antigravity, stale
    var base: NSColor {
        switch self {
        case .codex: hex(0xF4C75B)        // champagne yellow
        case .claude: hex(0xA58CEB)       // soft lavender
        case .antigravity: hex(0x86C9E8)  // ice blue
        case .stale: hex(0xB4B4BC)
        }
    }
}

enum HeartStyle: String { case soft, glass }

/// Studio environment for reflections: bright sky, a large soft box upper-left, darker floor.
func studioEnvironment() -> NSImage {
    let w = 1024, h = 512
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [hex(0xFFFFFF).cgColor, hex(0xE9ECF2).cgColor, hex(0x9A9DA6).cgColor, hex(0x4A4C52).cgColor] as CFArray,
                         locations: [0, 0.42, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    // Soft boxes: several positions so a highlight lands on the upper-left of the heart whatever the seam.
    for x in stride(from: 0, to: w, by: 256) {
        let box = CGRect(x: x + 40, y: Int(Double(h) * 0.62), width: 150, height: 110)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.fillPath()
    }
    image.unlockFocus()
    return image
}

final class HeartRenderer {
    let field: HeightField
    let outline: Path
    let renderer: SCNRenderer
    let environment = studioEnvironment()

    init() {
        outline = HeartShape().path(in: CGRect(x: 0, y: 0, width: 1, height: heartAspect))
        field = HeightField(path: outline)
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    }

    private lazy var outerSoft = HeartMesh.make(field: field, outline: outline, front: 0.30, back: 0.22)
    private lazy var outerGlass = HeartMesh.make(field: field, outline: outline, front: 0.30, back: 0.24)
    private lazy var innerJelly = HeartMesh.make(field: field, outline: outline, front: 0.24, back: 0.19, scale: 0.9)

    /// Renders one layer. `filled` selects the coloured (gauge-full) or empty variant of the same lit model.
    func render(style: HeartStyle, color: HeartColor, filled: Bool, pixelWidth: Int) -> CGImage {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = style == .glass ? 1.0 : 0.7

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(frameHeightUnits / 2)
        camera.zNear = 0.1; camera.zFar = 20
        camera.wantsHDR = false
        let cameraNode = SCNNode(); cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(cameraNode)

        addLights(to: scene, style: style)

        switch style {
        case .soft:
            let geometry = outerSoft.copy() as! SCNGeometry
            geometry.materials = [softMaterial(color: color, filled: filled)]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        case .glass:
            if filled {
                let jelly = innerJelly.copy() as! SCNGeometry
                jelly.materials = [jellyMaterial(color: color)]
                let node = SCNNode(geometry: jelly)
                node.position = SCNVector3(0, -0.012, 0)
                scene.rootNode.addChildNode(node)
            }
            let shell = outerGlass.copy() as! SCNGeometry
            shell.materials = [glassMaterial(color: color)]
            let shellNode = SCNNode(geometry: shell)
            shellNode.renderingOrder = 10
            scene.rootNode.addChildNode(shellNode)
        }

        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let size = CGSize(width: pixelWidth, height: Int((CGFloat(pixelWidth) * frameHeightUnits / frameWidthUnits).rounded()))
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: image.size)
        return premultiplied(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
    }


    /// Visible frame in heart widths: 18 × 16pt with a little margin around the silhouette.
    let frameWidthUnits: CGFloat = 1.04
    var frameHeightUnits: CGFloat { frameWidthUnits * 16 / 18 }

    private func addLights(to scene: SCNScene, style: HeartStyle) {
        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: NSColor, from direction: SCNVector3?) {
            let light = SCNLight(); light.type = type; light.intensity = intensity; light.color = color
            let node = SCNNode(); node.light = light
            if let direction {
                node.position = direction
                node.look(at: SCNVector3(0, 0, 0))
            }
            scene.rootNode.addChildNode(node)
        }
        // Key from upper-left front, cool fill from the right, warm bounce from below, and a rim from behind.
        light(.directional, style == .glass ? 520 : 760, hex(0xFFF8EE), from: SCNVector3(-2.2, 2.8, 3.4))
        light(.directional, 170, hex(0xE6EEFF), from: SCNVector3(3.0, 0.4, 2.0))
        light(.directional, 90, hex(0xFFF1E6), from: SCNVector3(0.2, -3.0, 1.4))
        light(.directional, style == .glass ? 260 : 140, .white, from: SCNVector3(0.6, 1.4, -3.0))
        light(.ambient, style == .glass ? 60 : 40, hex(0xF2F2F7), from: nil)
    }

    // Soft 3D: matte silicone. The empty variant is the same model in a pale tint of the hue.
    private func softMaterial(color: HeartColor, filled: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = filled ? color.base : mix(color.base, .white, 0.78)
        m.roughness.contents = 0.5
        m.metalness.contents = 0.0
        // A thin satin clear coat reads as soft silicone rather than chalky clay.
        m.clearCoat.contents = 0.35
        m.clearCoatRoughness.contents = 0.35
        return m
    }

    // Glass jelly: thin tinted shell with fresnel-weighted reflections.
    private func glassMaterial(color: HeartColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        // PBR ignores `transparency`/`fresnelExponent` the way Blinn uses them; the alpha must live in the
        // diffuse colour, and dual-layer draws the far side first so the shell reads as a thick volume.
        m.diffuse.contents = mix(color.base, .white, 0.5).withAlphaComponent(0.34)
        // A faint self-glow keeps the empty glass visible on dark menu bars.
        m.emission.contents = mix(color.base, .white, 0.6)
        m.emission.intensity = 0.12
        m.roughness.contents = 0.06
        m.metalness.contents = 0.0
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.03
        m.transparencyMode = .dualLayer
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    // The jelly core that rises with the remaining percent.
    private func jellyMaterial(color: HeartColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color.base.withAlphaComponent(0.9)
        m.roughness.contents = 0.25
        m.metalness.contents = 0.0
        m.clearCoat.contents = 0.6
        m.clearCoatRoughness.contents = 0.15
        m.blendMode = .alpha
        return m
    }
}

/// SceneKit's snapshot is tagged premultiplied-first but holds straight colour in translucent pixels
/// (e.g. A=100, R=144), so glass composited over a light bar blew out to white. Multiply it in.
func premultiplied(_ image: CGImage) -> CGImage {
    let width = image.width, height = image.height
    guard let data = image.dataProvider?.data, let source = CFDataGetBytePtr(data) else { return image }
    let rowBytes = image.bytesPerRow
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * rowBytes + x * 4
            // Memory order is BGRA for little-endian alpha-first, otherwise ARGB.
            let (a, r, g, b) = littleEndian
                ? (source[i + 3], source[i + 2], source[i + 1], source[i])
                : (source[i], source[i + 1], source[i + 2], source[i + 3])
            let o = (y * width + x) * 4
            bytes[o] = UInt8(Int(r) * Int(a) / 255)
            bytes[o + 1] = UInt8(Int(g) * Int(a) / 255)
            bytes[o + 2] = UInt8(Int(b) * Int(a) / 255)
            bytes[o + 3] = a
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}
