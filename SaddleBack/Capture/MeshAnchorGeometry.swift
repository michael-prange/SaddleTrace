import Foundation
import ARKit
import simd

/// A snapshot of one mesh anchor ready to render, with a coverage material index
/// (0 red / 1 yellow / 2 green) per face. Value type, so it crosses from the AR
/// queue to the main-actor renderer safely.
nonisolated struct CoverageMeshData: Sendable, Identifiable {
    let id: UUID
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    let perFaceMaterial: [UInt32]
    let transform: simd_float4x4
}

/// World-space coverage points for one mesh anchor, rendered as colored dots.
nonisolated struct CoveragePointData: Sendable, Identifiable {
    let id: UUID
    let points: [SIMD3<Float>]
    let colors: [SIMD3<Float>]
}

/// Reads `ARMeshAnchor` geometry (CPU-accessible buffers) into arrays and derives
/// per-face world data. Runs on the AR queue (nonisolated).
nonisolated enum MeshAnchorGeometry {

    static func positions(_ geometry: ARMeshGeometry) -> [SIMD3<Float>] {
        let src = geometry.vertices
        let ptr = src.buffer.contents()
        var out = [SIMD3<Float>](); out.reserveCapacity(src.count)
        for i in 0..<src.count {
            let raw = ptr.advanced(by: src.offset + i * src.stride)
                .assumingMemoryBound(to: (Float, Float, Float).self).pointee
            out.append(SIMD3<Float>(raw.0, raw.1, raw.2))
        }
        return out
    }

    static func indices(_ geometry: ARMeshGeometry) -> [UInt32] {
        let faces = geometry.faces
        let ptr = faces.buffer.contents()
        let total = faces.count * faces.indexCountPerPrimitive
        var out = [UInt32](repeating: 0, count: total)
        for i in 0..<total {
            out[i] = ptr.advanced(by: i * faces.bytesPerIndex)
                .assumingMemoryBound(to: UInt32.self).pointee
        }
        return out
    }

    /// Per-face world-space centroid and normal, for crediting coverage.
    static func faceCentroidsAndNormals(_ anchor: ARMeshAnchor)
        -> [(centroid: SIMD3<Float>, normal: SIMD3<Float>)] {
        let verts = positions(anchor.geometry)
        let idx = indices(anchor.geometry)
        let world = anchor.transform
        func toWorld(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = world * SIMD4<Float>(p, 1); return SIMD3<Float>(v.x, v.y, v.z)
        }
        var out: [(centroid: SIMD3<Float>, normal: SIMD3<Float>)] = []
        out.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count {
            let a = toWorld(verts[Int(idx[i])])
            let b = toWorld(verts[Int(idx[i + 1])])
            let c = toWorld(verts[Int(idx[i + 2])])
            out.append(((a + b + c) / 3, simd_normalize(simd_cross(b - a, c - a))))
            i += 3
        }
        return out
    }

    /// World-space vertices of a mesh anchor, colored by coverage state — for the
    /// see-through dot cloud.
    static func coveragePointData(for anchor: ARMeshAnchor, tracker: CoverageTracker,
                                  step: Int = 1) -> CoveragePointData? {
        let verts = positions(anchor.geometry)
        guard !verts.isEmpty else { return nil }
        let world = anchor.transform
        var points: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var i = 0
        while i < verts.count {
            let w = world * SIMD4<Float>(verts[i], 1)
            let p = SIMD3<Float>(w.x, w.y, w.z)
            points.append(p)
            colors.append(tracker.state(at: p).rgb)
            i += max(step, 1)
        }
        return CoveragePointData(id: anchor.identifier, points: points, colors: colors)
    }

    /// Builds renderable coverage data (local positions + per-face material index
    /// from the tracker's world-space state).
    static func coverageData(for anchor: ARMeshAnchor, tracker: CoverageTracker) -> CoverageMeshData? {
        let verts = positions(anchor.geometry)
        let idx = indices(anchor.geometry)
        guard idx.count >= 3, !verts.isEmpty else { return nil }

        let world = anchor.transform
        var perFace = [UInt32](); perFace.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count {
            let a = verts[Int(idx[i])], b = verts[Int(idx[i + 1])], c = verts[Int(idx[i + 2])]
            let localCentroid = (a + b + c) / 3
            let wc = world * SIMD4<Float>(localCentroid, 1)
            perFace.append(tracker.state(at: SIMD3<Float>(wc.x, wc.y, wc.z)).materialIndex)
            i += 3
        }
        return CoverageMeshData(id: anchor.identifier, positions: verts,
                                indices: idx, perFaceMaterial: perFace, transform: world)
    }
}
