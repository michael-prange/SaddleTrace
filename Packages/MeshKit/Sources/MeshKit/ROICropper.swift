import Foundation
import simd

/// Crops a mesh to the saddle region of interest (Design §7.4): the surface
/// whose closest spine point lies within the ROI arc-length span and within a
/// lateral limit (3D Euclidean distance) of the spine curve.
///
/// A face is kept when all three of its vertices are inside the ROI. Boundary
/// clipping of mixed faces is deferred to export (Design §7.4).
public enum ROICropper {

    public struct Configuration: Sendable {
        /// Maximum 3D distance from the spine curve (Design §7.4: 50 cm).
        public var lateralLimit: Double = 0.5
        public init() {}
    }

    public struct Result: Sendable {
        public let mesh: TriangleMesh
        public let insideVertexCount: Int
    }

    /// Returns the cropped mesh containing only faces fully inside the ROI, with
    /// vertices compacted and re-indexed.
    public static func crop(
        _ mesh: TriangleMesh,
        curve: SpineCurve,
        roiArcLength roi: ClosedRange<Double>,
        configuration: Configuration = Configuration()
    ) -> Result {
        let limit = configuration.lateralLimit

        // Classify each vertex.
        var inside = [Bool](repeating: false, count: mesh.vertexCount)
        for (i, v) in mesh.positions.enumerated() {
            let (s, d) = curve.closestPoint(to: SIMD3<Double>(v))
            inside[i] = roi.contains(s) && d <= limit
        }
        let insideCount = inside.lazy.filter { $0 }.count

        // Keep faces with all three vertices inside; compact the vertex set.
        var remap = [Int](repeating: -1, count: mesh.vertexCount)
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[3 * t])
            let b = Int(mesh.indices[3 * t + 1])
            let c = Int(mesh.indices[3 * t + 2])
            guard inside[a] && inside[b] && inside[c] else { continue }
            for original in [a, b, c] {
                if remap[original] == -1 {
                    remap[original] = positions.count
                    positions.append(mesh.positions[original])
                }
                indices.append(UInt32(remap[original]))
            }
        }

        return Result(mesh: TriangleMesh(positions: positions, indices: indices),
                      insideVertexCount: insideCount)
    }
}
