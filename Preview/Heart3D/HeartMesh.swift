// Inflated ("balloon") 3D heart mesh built from the app's 2D HeartShape outline.
// Height field: solve Poisson ∇²h = -1 inside the outline (h = 0 on it), then z = T·sqrt(h / max h).
// The square root gives a vertical tangent at the rim, so the silhouette rolls over like a balloon,
// and the Poisson solution is smooth (no medial-axis crease like a distance transform would leave).
import AppKit
import SceneKit
import SwiftUI

let heartAspect: CGFloat = 0.88   // same as JellyHeart.aspect

struct HeightField {
    let nx: Int, ny: Int
    let values: [Double]
    let maxValue: Double
    let inside: [Bool]

    init(path: Path, resolution: Int = 220, iterations: Int = 2500) {
        nx = resolution
        ny = Int((CGFloat(resolution) * heartAspect).rounded())
        let dx = 1.0 / Double(nx)
        var inside = [Bool](repeating: false, count: nx * ny)
        // SwiftUI's Path.contains flattens curves too coarsely on a 1-unit path (the lobes tested
        // as outside and the mesh became a diamond); CGPath.contains follows the real Béziers.
        let cgPath = path.cgPath
        for j in 0..<ny {
            for i in 0..<nx {
                let p = CGPoint(x: (Double(i) + 0.5) * dx, y: (Double(j) + 0.5) * dx)
                inside[j * nx + i] = cgPath.contains(p, using: .winding)
            }
        }
        var h = [Double](repeating: 0, count: nx * ny)
        let omega = 1.92, source = dx * dx
        for _ in 0..<iterations {
            for j in 1..<(ny - 1) {
                for i in 1..<(nx - 1) where inside[j * nx + i] {
                    let k = j * nx + i
                    let sum = h[k - 1] + h[k + 1] + h[k - nx] + h[k + nx]
                    h[k] += omega * ((sum + source) / 4 - h[k])
                }
            }
        }
        values = h
        maxValue = h.max() ?? 1
        self.inside = inside
    }

    /// Bilinear sample at unit-width coordinates (x right, y down).
    func sample(_ p: CGPoint) -> Double {
        let fx = Double(p.x) * Double(nx) - 0.5, fy = Double(p.y) * Double(nx) - 0.5
        let i0 = max(0, min(nx - 2, Int(floor(fx)))), j0 = max(0, min(ny - 2, Int(floor(fy))))
        let tx = max(0, min(1, fx - Double(i0))), ty = max(0, min(1, fy - Double(j0)))
        func v(_ i: Int, _ j: Int) -> Double { values[j * nx + i] }
        let top = v(i0, j0) * (1 - tx) + v(i0 + 1, j0) * tx
        let bottom = v(i0, j0 + 1) * (1 - tx) + v(i0 + 1, j0 + 1) * tx
        return max(0, top * (1 - ty) + bottom * ty) / maxValue
    }
}

enum HeartMesh {
    /// - Parameters:
    ///   - front/back: puff thickness of each side, in heart widths.
    ///   - scale: uniform x/y scale (inner jelly uses < 1).
    static func make(field: HeightField, outline: Path, front: CGFloat, back: CGFloat,
                     scale: CGFloat = 1, rings: Int = 56, segments: Int = 288,
                     center: CGPoint = CGPoint(x: 0.5, y: heartAspect * 0.56)) -> SCNGeometry {
        // Boundary points evenly spaced along the outline's length. A zero-length trim has no
        // currentPoint, so sample at half-step offsets (a nil there once became (0,0) and tore a spike).
        let boundary: [CGPoint] = (0..<segments).map { i in
            outline.trimmedPath(from: 0, to: (CGFloat(i) + 0.5) / CGFloat(segments)).currentPoint!
        }

        var positions: [SCNVector3] = []
        var indices: [UInt32] = []

        func to3D(_ p: CGPoint, _ z: CGFloat) -> SCNVector3 {
            SCNVector3((p.x - 0.5) * scale, (heartAspect / 2 - p.y) * scale, z)
        }

        func addSurface(sign: CGFloat, thickness: CGFloat) {
            let base = UInt32(positions.count)
            for k in 0..<rings {
                // Dense rings near the rim where curvature is highest.
                let s = pow(CGFloat(k) / CGFloat(rings), 1.8)
                for b in boundary {
                    let p = CGPoint(x: b.x + (center.x - b.x) * s, y: b.y + (center.y - b.y) * s)
                    positions.append(to3D(p, sign * thickness * scale * CGFloat(sqrt(field.sample(p)))))
                }
            }
            positions.append(to3D(center, sign * thickness * scale * CGFloat(sqrt(field.sample(center)))))
            let centerIndex = UInt32(positions.count - 1)
            let m = UInt32(segments)
            func idx(_ k: Int, _ i: Int) -> UInt32 { base + UInt32(k) * m + UInt32((i + segments) % segments) }
            for k in 0..<(rings - 1) {
                for i in 0..<segments {
                    let a = idx(k, i), b = idx(k, i + 1), c = idx(k + 1, i), d = idx(k + 1, i + 1)
                    indices += sign > 0 ? [a, c, b, b, c, d] : [a, b, c, b, d, c]
                }
            }
            for i in 0..<segments {
                let a = idx(rings - 1, i), b = idx(rings - 1, i + 1)
                indices += sign > 0 ? [a, centerIndex, b] : [a, b, centerIndex]
            }
        }
        addSurface(sign: 1, thickness: front)
        addSurface(sign: -1, thickness: back)

        // Smooth normals from accumulated face normals; fix global winding so the front faces +z.
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        func v(_ i: UInt32) -> SIMD3<Float> { let p = positions[Int(i)]; return SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        var faceSign: Float = 1
        do {
            let a = v(indices[0]), b = v(indices[1]), c = v(indices[2])
            // Probe a triangle near the front centre instead of the rim.
            let probe = (rings - 2) * segments * 6
            let pa = v(indices[probe]), pb = v(indices[probe + 1]), pc = v(indices[probe + 2])
            _ = (a, b, c)
            faceSign = simd_cross(pb - pa, pc - pa).z >= 0 ? 1 : -1
        }
        if faceSign < 0 {
            for t in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(t + 1, t + 2) }
        }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = v(indices[t]), b = v(indices[t + 1]), c = v(indices[t + 2])
            let n = simd_cross(b - a, c - a)
            for i in 0..<3 { normals[Int(indices[t + i])] += n }
        }
        let normalVectors = normals.map { n -> SCNVector3 in
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
            return SCNVector3(CGFloat(u.x), CGFloat(u.y), CGFloat(u.z))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normalVectors)],
                           elements: [element])
    }
}

/// Grid mesh straight from the height-field cells, for outlines that are not star-shaped (the bear's
/// ear notches folded the ring mesh into V-shaped creases). Rim vertices are pulled onto the exact
/// outline by bisection, so the silhouette stays smooth instead of stair-stepped.
enum GridMesh {
    static func make(field: HeightField, outline: Path, front: CGFloat, back: CGFloat,
                     scale: CGFloat = 1, pivot: CGPoint, exponent: Double = 0.5) -> SCNGeometry {
        let nx = field.nx, ny = field.ny
        let step = 1.0 / CGFloat(nx)
        let cgPath = outline.cgPath
        func cell(_ i: Int, _ j: Int) -> CGPoint { CGPoint(x: (CGFloat(i) + 0.5) * step, y: (CGFloat(j) + 0.5) * step) }
        func isInside(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i < nx && j < ny && field.inside[j * nx + i] }

        // 2D position and normalised height for every vertex that touches the shape.
        var planar = [CGPoint?](repeating: nil, count: nx * ny)
        var height = [CGFloat](repeating: 0, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let k = j * nx + i
                if isInside(i, j) {
                    planar[k] = cell(i, j)
                    height[k] = CGFloat(pow(field.values[k] / field.maxValue, exponent))
                    continue
                }
                // Outside vertex next to the shape: move it onto the outline.
                var neighbour: (Int, Int)?
                for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] where isInside(i + di, j + dj) {
                    neighbour = (i + di, j + dj); break
                }
                guard let (ni, nj) = neighbour else { continue }
                var outside = cell(i, j), inner = cell(ni, nj)
                for _ in 0..<14 {
                    let mid = CGPoint(x: (outside.x + inner.x) / 2, y: (outside.y + inner.y) / 2)
                    if cgPath.contains(mid, using: .winding) { inner = mid } else { outside = mid }
                }
                planar[k] = inner
            }
        }

        var positions: [SCNVector3] = []
        var indices: [UInt32] = []
        func to3D(_ p: CGPoint, _ z: CGFloat) -> SCNVector3 {
            SCNVector3(pivot.x - 0.5 + (p.x - pivot.x) * scale, heartAspect / 2 - pivot.y - (p.y - pivot.y) * scale, z)
        }
        for (sign, thickness) in [(CGFloat(1), front), (CGFloat(-1), back)] {
            var map = [Int32](repeating: -1, count: nx * ny)
            for k in 0..<(nx * ny) {
                guard let p = planar[k] else { continue }
                map[k] = Int32(positions.count)
                positions.append(to3D(p, sign * thickness * scale * height[k]))
            }
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    let a = map[j * nx + i], b = map[j * nx + i + 1], c = map[(j + 1) * nx + i], d = map[(j + 1) * nx + i + 1]
                    guard a >= 0, b >= 0, c >= 0, d >= 0 else { continue }
                    // Skip cells lying entirely on the rim (all four snapped outside): they would be flat skirts.
                    if !(isInside(i, j) || isInside(i + 1, j) || isInside(i, j + 1) || isInside(i + 1, j + 1)) { continue }
                    let (ua, ub, uc, ud) = (UInt32(a), UInt32(b), UInt32(c), UInt32(d))
                    // Image y grows downward, 3D y upward: this winding faces +z on the front.
                    indices += sign > 0 ? [ua, ub, uc, ub, ud, uc] : [ua, uc, ub, ub, uc, ud]
                }
            }
        }

        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        func v(_ i: UInt32) -> SIMD3<Float> { let p = positions[Int(i)]; return SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let n = simd_cross(v(indices[t + 1]) - v(indices[t]), v(indices[t + 2]) - v(indices[t]))
            for i in 0..<3 { normals[Int(indices[t + i])] += n }
        }
        let normalVectors = normals.map { n -> SCNVector3 in
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
            return SCNVector3(CGFloat(u.x), CGFloat(u.y), CGFloat(u.z))
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normalVectors)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
