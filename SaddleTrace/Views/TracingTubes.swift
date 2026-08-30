import SceneKit
import simd
import UIKit

/// Builds bold, always-on-top tube geometry for the spine + cross-section tracing
/// polylines, shared by the painted-model and point-cloud 3D viewers. The first
/// polyline is the spine (green); the rest are the 4-inch cross-sections (cyan),
/// so the fitter can tell them apart. Tubes ignore the depth buffer and render
/// after the surface, so they can't z-fight / flicker as the model rotates.
enum TracingTubes {
    static let spineColor = UIColor(red: 0.1, green: 1.0, blue: 0.3, alpha: 1)
    static let sectionColor = UIColor(red: 0.1, green: 0.85, blue: 1.0, alpha: 1)

    /// Nodes for the tracings in `url` (world frame), recentered by `center`, with a
    /// tube radius sized relative to `modelExtent` (the bounding-box diagonal, m).
    /// `radiusScale` thins/thickens the tubes (e.g. thinner for the PDF snapshot).
    static func nodes(tracingsURL url: URL?, center: SIMD3<Float>, modelExtent: Float,
                      radiusScale: Float = 1) -> [SCNNode] {
        guard let url, let lines = try? PolylineIO.read(url), !lines.isEmpty else { return [] }
        let radius = max(modelExtent * 0.006, 0.003) * radiusScale
        var nodes: [SCNNode] = []
        if let spine = geometry(Array(lines.prefix(1)), center: center, radius: radius, color: spineColor) {
            let n = SCNNode(geometry: spine); n.renderingOrder = 10; nodes.append(n)
        }
        if let sections = geometry(Array(lines.dropFirst()), center: center, radius: radius, color: sectionColor) {
            let n = SCNNode(geometry: sections); n.renderingOrder = 10; nodes.append(n)
        }
        return nodes
    }

    /// A single tube geometry from polylines (recentered by `center`); each polyline
    /// becomes a `sides`-sided tube of `radius`.
    static func geometry(
        _ lines: [[SIMD3<Float>]], center: SIMD3<Float>, radius: Float,
        color: UIColor, sides: Int = 8
    ) -> SCNGeometry? {
        func norm(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let l = simd_length(v); return l > 1e-6 ? v / l : SIMD3<Float>(0, 0, 1)
        }

        var verts: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var idx: [UInt32] = []

        for line in lines where line.count >= 2 {
            let pts = line.map { $0 - center }
            var ringBase: [UInt32] = []
            for i in 0..<pts.count {
                let tangent: SIMD3<Float>
                if i == 0 { tangent = norm(pts[1] - pts[0]) }
                else if i == pts.count - 1 { tangent = norm(pts[i] - pts[i - 1]) }
                else { tangent = norm(pts[i + 1] - pts[i - 1]) }
                var ref = SIMD3<Float>(0, 1, 0)
                if abs(simd_dot(ref, tangent)) > 0.9 { ref = SIMD3<Float>(1, 0, 0) }
                let n1 = norm(simd_cross(tangent, ref))
                let n2 = norm(simd_cross(tangent, n1))
                ringBase.append(UInt32(verts.count))
                for s in 0..<sides {
                    let a = Float(s) / Float(sides) * 2 * .pi
                    let dir = cos(a) * n1 + sin(a) * n2
                    let p = pts[i] + dir * radius
                    verts.append(SCNVector3(p.x, p.y, p.z))
                    normals.append(SCNVector3(dir.x, dir.y, dir.z))
                }
            }
            for i in 0..<(pts.count - 1) {
                let a = ringBase[i], b = ringBase[i + 1]
                for s in 0..<sides {
                    let s2 = (s + 1) % sides
                    let a0 = a + UInt32(s), a1 = a + UInt32(s2)
                    let b0 = b + UInt32(s), b1 = b + UInt32(s2)
                    idx += [a0, b0, a1, a1, b0, b1]
                }
            }
        }

        guard !idx.isEmpty else { return nil }
        let vs = SCNGeometrySource(vertices: verts)
        let ns = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vs, ns], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        // No depth read or write; drawn after the surface (renderingOrder) so the
        // curves stay on top and never z-fight.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }
}
