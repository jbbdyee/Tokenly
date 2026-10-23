// Small-eared glass jelly bear (reference option C), rendered as a real inflated 3D mesh in SceneKit.
// Empty and full layers share geometry, camera and lights; only the inner jelly colour differs, so a
// per-row blend between them at runtime keeps the 3D volume at any percentage.
import AppKit
import SceneKit
import SwiftUI

/// Bear head outline in the same 1 × 0.88 unit frame the heart used:
/// a wide superellipse face (keeps the centre roomy for digits) plus two small, flattened ears.
/// `earScale` scales only the ears about their own centres (1.05 = ears 5% larger, face unchanged).
func bearOutline(earScale: CGFloat = 1) -> Path {
    func superellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, n: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<360 {
            let t = CGFloat(i) / 360 * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = cx + rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = cy + ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
    let face = superellipse(cx: 0.5, cy: 0.49, rx: 0.5, ry: 0.385, n: 2.2)
    let rx = 0.11 * earScale, ry = 0.085 * earScale
    let leftEar = CGPath(ellipseIn: CGRect(x: 0.19 - rx, y: 0.15 - ry, width: rx * 2, height: ry * 2), transform: nil)
    let rightEar = CGPath(ellipseIn: CGRect(x: 0.81 - rx, y: 0.15 - ry, width: rx * 2, height: ry * 2), transform: nil)
    return Path(face.union(leftEar, using: .winding).union(rightEar, using: .winding))
}

let bearCenter = CGPoint(x: 0.5, y: 0.49)

enum BearColor: String, CaseIterable {
    case codex, claude, antigravity, stale
    /// Confirmed service colours; stale stays neutral grey.
    var base: NSColor {
        switch self {
        case .codex: hex(0xF4C75B)        // champagne yellow
        case .claude: hex(0xA58CEB)       // soft lavender
        case .antigravity: hex(0x86C9E8)  // ice blue
        case .stale: hex(0xB2B3BA)
        }
    }
    /// Slightly richer core so the jelly reads saturated through the clear shell, like the reference.
    var core: NSColor {
        switch self {
        case .codex: hex(0xF3BE48)
        case .claude: hex(0x9C82EA)
        case .antigravity: hex(0x72C1E8)
        case .stale: hex(0xA2A3AB)
        }
    }
}

final class BearRenderer {
    let outline: Path
    init(earScale: CGFloat = 1) { outline = bearOutline(earScale: earScale) }
    lazy var field = HeightField(path: outline, resolution: 300, iterations: 4000)
    // Exponent 0.4 (vs. 0.5) lets the small ears dome up instead of staying flat "horns",
    // while the face keeps a balloon curve (0.32 flattened it into a cushion).
    lazy var shell = GridMesh.make(field: field, outline: outline, front: 0.38, back: 0.26, pivot: bearCenter, exponent: 0.4)
    // Core scaled about the face centre so its ears stay inside the shell's ears; thin clear rim.
    lazy var core = GridMesh.make(field: field, outline: outline, front: 0.34, back: 0.22, scale: 0.965, pivot: bearCenter,
                                  exponent: 0.4)
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    let environment = bearEnvironment()

    /// Frame in units: 1.04 wide, 16/18 of that high (18 × 16pt at menu bar size).
    let frameWidthUnits: CGFloat = 1.04
    var frameHeightUnits: CGFloat { frameWidthUnits * 16 / 18 }

    func render(color: BearColor, filled: Bool, pixelWidth: Int) -> CGImage {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 0.75

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(frameHeightUnits / 2)
        camera.zNear = 0.1; camera.zFar = 20
        let cameraNode = SCNNode(); cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(cameraNode)

        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: NSColor, _ from: SCNVector3?) {
            let l = SCNLight(); l.type = type; l.intensity = intensity; l.color = color
            let node = SCNNode(); node.light = l
            if let from { node.position = from; node.look(at: SCNVector3(0, 0, 0)) }
            scene.rootNode.addChildNode(node)
        }
        light(.directional, 760, hex(0xFFF9F0), SCNVector3(-1.6, 2.2, 3.0))   // key, upper left: main highlight
        light(.directional, 140, hex(0xEAF1FF), SCNVector3(3.0, 0.2, 2.2))    // cool fill
        light(.directional, 650, .white, SCNVector3(0.0, 3.0, -1.2))          // top rim: bright edge along the crown
        light(.directional, 130, hex(0xFFF3E4), SCNVector3(0.0, -3.0, 1.0))   // warm bounce into the chin
        light(.ambient, 30, hex(0xF4F4F8), nil)

        // Inner jelly: saturated when filled, a pale milky jelly when empty (never see-through to the bar).
        let coreGeometry = core.copy() as! SCNGeometry
        let jelly = SCNMaterial()
        jelly.lightingModel = .physicallyBased
        let coreColor = filled ? color.core : mix(color.base, .white, 0.8)
        jelly.diffuse.contents = coreColor.withAlphaComponent(filled ? 0.96 : 0.9)
        jelly.roughness.contents = 0.22
        jelly.metalness.contents = 0.0
        jelly.clearCoat.contents = 0.5
        jelly.clearCoatRoughness.contents = 0.12
        // Soft self-glow stands in for subsurface scattering (SceneKit has none).
        jelly.emission.contents = mix(coreColor, .white, 0.35)
        jelly.emission.intensity = filled ? 0.08 : 0.1
        jelly.blendMode = .alpha
        coreGeometry.materials = [jelly]
        let coreNode = SCNNode(geometry: coreGeometry)
        coreNode.position = SCNVector3(0, -0.01, 0)
        scene.rootNode.addChildNode(coreNode)

        // Clear glass shell with a strong clear coat for crisp reflections along the curved edge.
        let shellGeometry = shell.copy() as! SCNGeometry
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = mix(color.base, .white, 0.6).withAlphaComponent(0.16)
        glass.roughness.contents = 0.04
        glass.metalness.contents = 0.0
        glass.clearCoat.contents = 1.0
        glass.clearCoatRoughness.contents = 0.02
        glass.emission.contents = mix(color.base, .white, 0.6)
        glass.emission.intensity = 0.05
        glass.transparencyMode = .dualLayer
        glass.blendMode = .alpha
        glass.writesToDepthBuffer = false
        glass.isDoubleSided = true
        shellGeometry.materials = [glass]
        let shellNode = SCNNode(geometry: shellGeometry)
        shellNode.renderingOrder = 10
        scene.rootNode.addChildNode(shellNode)

        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let size = CGSize(width: pixelWidth, height: Int((CGFloat(pixelWidth) * frameHeightUnits / frameWidthUnits).rounded()))
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: image.size)
        return premultiplied(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
    }
}

/// Plain studio gradient (no soft-box tiles), so reflections stay one clean highlight plus the rim.
func bearEnvironment() -> NSImage {
    let w = 1024, h = 512
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [hex(0xFFFFFF).cgColor, hex(0xDCDFE6).cgColor, hex(0x7E828C).cgColor, hex(0x3A3C42).cgColor] as CFArray,
                              locations: [0, 0.38, 0.55, 1])!
    NSGraphicsContext.current!.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    image.unlockFocus()
    return image
}
