// Tokenly concept D refinement — three glass orbs, rendered with an analytic sphere shader plus an
// illustration layer for the overlaps. A pure physical (subtractive) glass model turned the triple
// overlap into a dark violet, while the reference shows a light, luminous pink there, so each overlap
// region takes its colour from a palette sampled off the reference and the sphere geometry supplies
// the shading (bottom glow, glass thickness band, rim, curved highlights, soft shadow).
// Final candidate (DF): D1 colour + softened D3 highlights + lens-like overlaps — every orb covering a
// pixel adds its own limb/bottom-glow shading (so each overlap reads as a lens, not a flat shape),
// orbs behind are seen slightly refracted near the front orb's rim, and the inside of each boundary
// gets a faint light bleed.
// Usage: finalorb DF <out.png> [size=2048]
import AppKit
import Foundation
import simd

typealias V3 = SIMD3<Float>
typealias V2 = SIMD2<Float>
@inline(__always) func rgb(_ h: UInt32) -> V3 { V3(Float((h >> 16) & 255), Float((h >> 8) & 255), Float(h & 255)) / 255 }
@inline(__always) func mixv(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
@inline(__always) func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t) }
/// 1 inside [a, b] with soft shoulders of width f.
@inline(__always) func band(_ x: Float, _ a: Float, _ b: Float, _ f: Float) -> Float { smoothstep(a - f, a + f, x) * (1 - smoothstep(b - f, b + f, x)) }

// MARK: - Geometry (measured on the reference with a 0.1-unit grid; plate spans −1…1, y up)

struct Orb { let c: V2; let r: Float; let rim: V3; let deep: V3 }
// Back-to-front: yellow, blue, lavender.
let orbs = [
    Orb(c: V2(0.30, -0.278), r: 0.507, rim: rgb(0xF0BC5E), deep: rgb(0xFFCC74)),   // 0 champagne yellow
    Orb(c: V2(-0.33, -0.19), r: 0.505, rim: rgb(0x78B0F5), deep: rgb(0x8EC4FB)),   // 1 ice blue
    Orb(c: V2(0.03, 0.276), r: 0.517, rim: rgb(0xA48AEC), deep: rgb(0xBDA3F4)),    // 2 lavender
]

// MARK: - Overlap palette (top / middle / bottom of each region, sampled from the reference)

struct RegionPalette { let top: V3, mid: V3, bottom: V3, vTop: Float, vBottom: Float }
/// Key: bit 0 yellow, bit 1 blue, bit 2 lavender. Values are the reference samples minus the lift the
/// shading layers add (measured), so the final mid-tones land on the reference.
let palette: [Int: RegionPalette] = [
    0b001: RegionPalette(top: rgb(0xFEE0A5), mid: rgb(0xFED383), bottom: rgb(0xFEE7B1), vTop: 0.23, vBottom: -0.79),  // Y
    0b010: RegionPalette(top: rgb(0xA4CFFD), mid: rgb(0x99CCFD), bottom: rgb(0xC9E7FE), vTop: 0.32, vBottom: -0.70),  // B
    0b100: RegionPalette(top: rgb(0xD1B9F8), mid: rgb(0xCDB5F9), bottom: rgb(0xD6C6FA), vTop: 0.79, vBottom: -0.24),  // P
    0b110: RegionPalette(top: rgb(0xACA2F8), mid: rgb(0xA499F7), bottom: rgb(0xB5ADF9), vTop: 0.32, vBottom: -0.24),  // P+B
    0b101: RegionPalette(top: rgb(0xD8AFE6), mid: rgb(0xDBB1E7), bottom: rgb(0xE1BCEB), vTop: 0.23, vBottom: -0.24),  // P+Y
    0b011: RegionPalette(top: rgb(0xB9C4EA), mid: rgb(0xC2CAEA), bottom: rgb(0xD5DAF0), vTop: -0.22, vBottom: -0.62), // B+Y
    0b111: RegionPalette(top: rgb(0xD4B4F5), mid: rgb(0xD7B8F7), bottom: rgb(0xDDC0F8), vTop: -0.05, vBottom: -0.24), // all three
]

// MARK: - Variants

struct Style {
    var transparency: Float     // 0 = reference colours; > 0 lets more of the plate through (lighter, clearer)
    var rimLine: Float          // thin saturated edge line
    var thickness: Float        // bright inner band (glass wall seen edge-on)
    var bottomGlow: Float       // extra light gathered in the lower interior
    var highlight: Float        // curved specular streaks + spot
    var highlightSharp: Float   // 1 = reference softness, > 1 crisper
    var backRim: Float          // how strongly rims of orbs behind show through the front ones
    var upperShade: Float       // faint darkening just inside the upper rim (volume)
    var edgeTint: Float         // coloured reflection along the rim
    var depth: Float = 0.5      // limb saturation (volume)
    var sheen: Float = 0.10     // broad upper-left interior sheen
    var lensDepth: Float = 0    // shading contributed by orbs behind the front one (overlap depth)
    var refract: Float = 0      // displacement of orbs seen through the front orb's rim (plate units)
    var boundaryGlow: Float = 0 // light bleed just inside boundaries seen through another orb
    var backGlint: Float = 0.45 // highlights of covered orbs
}
let styles: [String: Style] = [
    "DF": Style(transparency: 0, rimLine: 0.36, thickness: 0.30, bottomGlow: 0.12, highlight: 0.76, highlightSharp: 1.3,
                backRim: 0.6, upperShade: 0.04, edgeTint: 0.06, depth: 0.6, sheen: 0.10,
                lensDepth: 0.55, refract: 0.022, boundaryGlow: 0.14, backGlint: 0.6),
    "D1": Style(transparency: 0, rimLine: 0.38, thickness: 0.28, bottomGlow: 0.10, highlight: 0.68, highlightSharp: 1.0,
                backRim: 0.5, upperShade: 0.0, edgeTint: 0.0, depth: 0.55, sheen: 0.10),
    "D2": Style(transparency: 0.18, rimLine: 0.5, thickness: 0.45, bottomGlow: 0.15, highlight: 0.68, highlightSharp: 1.0,
                backRim: 0.7, upperShade: 0.0, edgeTint: 0.4, depth: 0.45, sheen: 0.08),
    "D3": Style(transparency: 0.03, rimLine: 0.42, thickness: 0.32, bottomGlow: 0.14, highlight: 0.85, highlightSharp: 1.6,
                backRim: 0.55, upperShade: 0.08, edgeTint: 0.15, depth: 0.7, sheen: 0.12),
]

// MARK: - Plate

func roundedSquare(_ x: Float, _ y: Float) -> Float {   // < 1 inside; matches the reference plate corners
    let rc: Float = 0.40, n: Float = 4
    let qx = max(abs(x) - (1 - rc), 0), qy = max(abs(y) - (1 - rc), 0)
    if qx == 0 && qy == 0 { return max(abs(x), abs(y)) }
    return (1 - rc) + rc * pow(pow(qx / rc, n) + pow(qy / rc, n), 1 / n)
}

func plate(_ p: V2) -> V3 {
    let u = clamp01((p.x + 1) / 2), v = clamp01((p.y + 1) / 2)
    let top = mixv(rgb(0xFCF8F8), rgb(0xF2F7FB), u), bottom = mixv(rgb(0xF3F2F9), rgb(0xEEF2F8), u)
    var c = mixv(bottom, top, v)
    // Very faint pink bloom in the top-left corner, as on the reference plate.
    c = mixv(c, rgb(0xFBEEF3), 0.55 * (1 - smoothstep(0.0, 1.05, simd_length(p - V2(-1.0, 1.0)))))
    // Soft coloured shadow under each orb (offset down, wide blur, low contrast).
    var shade: Float = 0
    var tint = V3.zero, tw: Float = 0
    for (i, o) in orbs.enumerated() {
        let q = (p - (o.c + V2(0.02, -0.10))) / (o.r * 1.0)
        let d = simd_length(V2(q.x, q.y * 1.08))
        let s = (1 - smoothstep(0.4, 1.3, d)) * 0.40
        shade = max(shade, s)
        let col = i == 0 ? rgb(0xE9C98F) : i == 1 ? rgb(0x9DC4F0) : rgb(0xB4A2EA)
        tint += col * s; tw += s
    }
    if tw > 0 { c = c * mixv(.one, mixv(tint / tw, rgb(0x9A98B8), 0.5), shade * 2.2) }
    return c
}

// MARK: - Orb shading

func shade(_ p: V2, _ st: Style) -> V3? {
    var mask = 0
    var front = -1
    var qs = [V2](repeating: .zero, count: 3), ds = [Float](repeating: 9, count: 3)
    for (i, o) in orbs.enumerated() {
        let q = (p - o.c) / o.r; qs[i] = q; ds[i] = simd_length(q)
        if ds[i] < 1 { mask |= 1 << i; front = i }
    }
    if mask == 0 { return nil }
    // Orbs behind the front one are seen through its curved rim: shift their lookup outward a little
    // near the rim, so their boundaries bend like they do through a real lens.
    if st.refract > 0 {
        let qf0 = qs[front], df0 = ds[front]
        let pull = st.refract * pow(smoothstep(0.55, 1.0, df0), 2)
        let pp = p + (df0 > 1e-4 ? qf0 / df0 : .zero) * pull
        mask = 1 << front
        for i in 0..<front {
            let q = (pp - orbs[i].c) / orbs[i].r; qs[i] = q; ds[i] = simd_length(q)
            if ds[i] < 1 { mask |= 1 << i }
        }
    }
    let pal = palette[mask]!
    let t = clamp01((pal.vTop - p.y) / (pal.vTop - pal.vBottom))
    var c = t < 0.5 ? mixv(pal.top, pal.mid, t * 2) : mixv(pal.mid, pal.bottom, (t - 0.5) * 2)

    // Clearer glass: let the plate through (keeps hue, lowers density).
    if st.transparency > 0 { c = mixv(c, plate(p), st.transparency) }

    let qf = qs[front], df = ds[front]
    let dir = df > 1e-4 ? qf / df : V2(0, 1)
    // Volume: colour deepens toward the limb, mostly on the upper-left (thicker glass against the light).
    let limb = pow(1 - sqrt(max(0, 1 - df * df)), 1.6)
    let ul = clamp01(0.35 + 0.65 * simd_dot(dir, simd_normalize(V2(-0.6, 0.8))))
    c = mixv(c, mixv(orbs[front].deep, c, 0.35), limb * st.depth * ul)
    // Broad soft sheen in the upper-left interior.
    let sheen = 1 - smoothstep(0.0, 0.62, simd_length((qf - V2(-0.28, 0.34)) / V2(1.0, 0.8)))
    c = mixv(c, .one, sheen * st.sheen)
    // Light gathered in the lower interior: a soft crescent above the bottom rim.
    let ang = atan2(qf.y, qf.x) * 180 / .pi
    let crescent = band(df, 0.58, 0.95, 0.12) * band(ang, -150, -25, 30)
    c = mixv(c, .one, crescent * st.bottomGlow * 2.6)

    // Each orb behind the front one shades its own part of the overlap (lens depth).
    if st.lensDepth > 0 {
        for i in 0..<front where ds[i] < 1 {
            let q = qs[i], d = ds[i], dirI = d > 1e-4 ? q / d : V2(0, 1)
            let limbI = pow(1 - sqrt(max(0, 1 - d * d)), 1.6)
            let ulI = clamp01(0.35 + 0.65 * simd_dot(dirI, simd_normalize(V2(-0.6, 0.8))))
            c = mixv(c, mixv(orbs[i].deep, c, 0.5), limbI * st.depth * ulI * st.lensDepth)
            let angI = atan2(q.y, q.x) * 180 / .pi
            let cres = band(d, 0.58, 0.95, 0.12) * band(angI, -150, -25, 30)
            c = mixv(c, .one, cres * st.bottomGlow * 2.6 * st.lensDepth)
            // Light bleed just inside the boundary seen through the front orb.
            c = mixv(c, .one, band(d, 0.90, 0.995, 0.03) * st.boundaryGlow)
        }
    }

    // Faint volume shade just inside the upper rim.
    if st.upperShade > 0 {
        let up = smoothstep(0.2, 0.9, qf.y) * band(df, 0.80, 0.97, 0.05)
        c = c * (1 - up * st.upperShade)
    }

    // Edges of every orb (front ones fully, ones seen through a front orb more faintly).
    for (i, o) in orbs.enumerated() where ds[i] < 1.0 {
        var covered = false
        for j in (i + 1)..<3 where ds[j] < 1 { covered = true }
        let k: Float = covered ? st.backRim : 1
        let q = qs[i], d = ds[i]
        let angleLower = smoothstep(0.6, -0.6, q.y)      // 1 at the bottom
        // Glass wall seen edge-on: bright band, strongest along the bottom.
        let wall = band(d, 0.905, 0.972, 0.018) * (0.45 + 0.55 * angleLower)
        c = mixv(c, .one, wall * st.thickness * k)
        // Coloured reflection of the neighbouring orb along the rim (D2/D3).
        if st.edgeTint > 0 {
            // Coloured internal reflection just inside the rim, brightest on the upper half.
            let refl = band(d, 0.935, 0.982, 0.01) * (0.4 + 0.6 * (1 - angleLower))
            c = mixv(c, mixv(o.deep, .one, 0.2), refl * st.edgeTint * k)
        }
        // Thin saturated rim line.
        let line = band(d, 0.978, 1.0, 0.006) * (1 - 0.55 * angleLower)
        c = mixv(c, mixv(o.rim, c, 0.25), line * st.rimLine * k)
    }

    // Curved highlights on each orb (dimmed when seen through another orb).
    for (i, _) in orbs.enumerated() where ds[i] < 1.0 {
        var covered = false
        for j in (i + 1)..<3 where ds[j] < 1 { covered = true }
        let k: Float = covered ? st.backGlint : 1
        let q = qs[i], d = ds[i]
        let ang = atan2(q.y, q.x) * 180 / .pi
        let sharp = st.highlightSharp
        /// Soft ellipse at polar position (ρ, θ°), long axis along the sphere's tangent (follows the curvature).
        func glint(_ rho: Float, _ theta: Float, _ major: Float, _ minor: Float) -> Float {
            let t = theta * .pi / 180
            let centre = V2(cos(t), sin(t)) * rho, tangent = V2(-sin(t), cos(t)), radial = V2(cos(t), sin(t))
            let w = q - centre
            let e = simd_length(V2(simd_dot(w, tangent) / major, simd_dot(w, radial) / minor))
            return 1 - smoothstep(1 - 0.55 * min(1, sharp * 0.75), 1.0, e)
        }
        // Main streak: inside the upper-left crown, long axis following the curve.
        let s1 = glint(0.69, 132, 0.25, 0.075)
        // Secondary streak on the upper-right.
        let s2 = glint(0.79, 38, 0.17, 0.045) * 0.55
        // Small spot beside the main streak.
        let s3 = glint(0.47, 106, 0.05, 0.036) * 0.85
        // Faint rim light on the lower-right (kicker), keeps the bottom from going flat.
        let s4 = band(d, 0.88, 0.96, 0.03) * band(ang, -75, -20, 12) * 0.35
        let h = max(max(s1, s2), max(s3, s4)) * st.highlight * k
        c = mixv(c, .one, h)
    }
    return c
}

// MARK: - Render

let args = CommandLine.arguments
let style = styles[args[1]]!
let size = args.count > 3 ? Int(args[3])! : 2048
let plateFrac: Float = 824.0 / 1024.0
let ss = 3
var px = [UInt8](repeating: 0, count: size * size * 4)
px.withUnsafeMutableBufferPointer { buf in
    let b = buf.baseAddress!
    DispatchQueue.concurrentPerform(iterations: size) { row in
        for col in 0..<size {
            var acc = V3.zero, cover: Float = 0
            for sy in 0..<ss { for sx in 0..<ss {
                let fx = (Float(col) + (Float(sx) + 0.5) / Float(ss)) / Float(size) * 2 - 1
                let fy = 1 - (Float(row) + (Float(sy) + 0.5) / Float(ss)) / Float(size) * 2
                let p = V2(fx, fy) / plateFrac
                let sq = roundedSquare(p.x, p.y)
                if sq > 1 { continue }
                var c = shade(p, style) ?? plate(p)
                // Plate bevel: faint light rim top-left, faint darker rim bottom-right.
                let rim = 1 - smoothstep(0.0, 0.035, 1 - sq)
                let side = clamp01(0.5 + 0.6 * (p.y - p.x) / 1.4)
                c = mixv(c, .one, rim * 0.45 * side); c = c * (1 - rim * 0.06 * (1 - side))
                acc += c; cover += 1
            } }
            let a = cover / Float(ss * ss), c = cover > 0 ? acc / cover : .zero
            let o = (row * size + col) * 4
            b[o] = UInt8(clamp01(c.x * a) * 255 + 0.5); b[o + 1] = UInt8(clamp01(c.y * a) * 255 + 0.5)
            b[o + 2] = UInt8(clamp01(c.z * a) * 255 + 0.5); b[o + 3] = UInt8(a * 255 + 0.5)
        }
    }
}
let img = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print(args[1], size)
