import Foundation
import simd

/// An indexed triangle mesh in metres.
///
/// Coordinate convention used throughout MeshKit after normalization
/// (see `LongAxisNormalizer`). This is a **Z-up** frame (CAD/DXF/Blender
/// convention), chosen for clean downstream export; ARKit's native Y-up output
/// is swapped to this frame at the capture→MeshKit boundary:
/// - **+X** cranio-caudal (the animal's long axis, head toward −X once oriented)
/// - **+Y** lateral
/// - **+Z** dorsal / up (vertical)
///
/// Positions are stored as `Float` to match ARKit / RealityKit output. Geometric
/// fits that need numerical headroom (PCA, spline solves) promote to `Double`
/// internally.
public struct TriangleMesh: Sendable, Equatable {
    /// Vertex positions in metres.
    public var positions: [SIMD3<Float>]
    /// Triangle corner indices, three consecutive entries per face.
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>], indices: [UInt32]) {
        precondition(indices.count.isMultiple(of: 3), "indices must be a multiple of 3")
        self.positions = positions
        self.indices = indices
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }

    /// The three corner positions of triangle `i`.
    public func triangle(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let base = 3 * i
        return (positions[Int(indices[base])],
                positions[Int(indices[base + 1])],
                positions[Int(indices[base + 2])])
    }

    /// Axis-aligned bounding box. Returns zeros for an empty mesh.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = positions.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for p in positions.dropFirst() {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// Returns a copy with every vertex position transformed by `m` (affine,
    /// w = 1). Indices are unchanged.
    public func transformed(by m: simd_float4x4) -> TriangleMesh {
        let moved = positions.map { p -> SIMD3<Float> in
            let v = m * SIMD4<Float>(p, 1)
            return SIMD3<Float>(v.x, v.y, v.z)
        }
        return TriangleMesh(positions: moved, indices: indices)
    }

    /// Centroid of all vertices.
    public var vertexCentroid: SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        var sum = SIMD3<Double>.zero
        for p in positions { sum += SIMD3<Double>(p) }
        return SIMD3<Float>(sum / Double(positions.count))
    }
}
