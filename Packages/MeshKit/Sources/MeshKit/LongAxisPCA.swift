import Foundation
import simd

/// Fits the animal's long (cranio-caudal) axis from the mesh, per Design §7.1.
///
/// The floor and legs are excluded by keeping only the "top region" — vertices
/// whose vertical coordinate (Z, in MeshKit's Z-up frame) exceeds a threshold.
/// PCA then runs in the horizontal (XY) plane; the first principal component is
/// the long axis. The head/tail *sign* is intentionally left unresolved here —
/// `LandmarkDetector` disambiguates it once the withers are located.
public enum LongAxisPCA {

    /// The fitted long axis as a unit vector lying in the XY plane (`z == 0`).
    ///
    /// - Parameters:
    ///   - mesh: input mesh in the Z-up frame.
    ///   - topRegionMinHeight: vertices with `z <= this` are treated as legs/
    ///     ground and ignored. Assumes the floor is near `z = 0` (Design §7.1
    ///     uses 0.8 m). If fewer than three vertices survive the filter, PCA
    ///     falls back to the whole mesh.
    /// - Returns: a unit direction; sign is canonicalized (non-negative X, then
    ///   non-negative Y) and carries no head/tail meaning.
    public static func longAxis(of mesh: TriangleMesh, topRegionMinHeight: Float = 0.8) -> SIMD3<Float> {
        var pts = mesh.positions.filter { $0.z > topRegionMinHeight }
        if pts.count < 3 { pts = mesh.positions }
        guard pts.count >= 2 else { return SIMD3<Float>(1, 0, 0) }

        // Mean of the horizontal projection.
        var mx = 0.0, my = 0.0
        for p in pts { mx += Double(p.x); my += Double(p.y) }
        let n = Double(pts.count)
        mx /= n; my /= n

        // 2×2 covariance in XY.
        var a = 0.0, b = 0.0, c = 0.0
        for p in pts {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            a += dx * dx; b += dx * dy; c += dy * dy
        }
        a /= n; b /= n; c /= n

        // Eigenvector of the larger eigenvalue of the symmetric matrix [[a,b],[b,c]].
        let half = (a + c) / 2
        let disc = ((a - c) / 2) * ((a - c) / 2) + b * b
        let lambda1 = half + disc.squareRoot()

        var vx: Double, vy: Double
        if abs(b) > 1e-12 {
            vx = b; vy = lambda1 - a
        } else {
            (vx, vy) = a >= c ? (1, 0) : (0, 1)
        }
        let len = (vx * vx + vy * vy).squareRoot()
        vx /= len; vy /= len

        // Canonical sign (no head/tail meaning).
        if vx < 0 || (vx == 0 && vy < 0) { vx = -vx; vy = -vy }
        return SIMD3<Float>(Float(vx), Float(vy), 0)
    }
}

/// Rotates a mesh about the vertical (Z) axis so its long axis aligns with +X,
/// establishing MeshKit's canonical working frame (Design §7.2 precondition).
public enum LongAxisNormalizer {

    /// The normalized mesh and the transform that produced it.
    public struct Result: Sendable {
        public let mesh: TriangleMesh
        /// The applied world→normalized transform (rotation about a vertical
        /// axis through the top-region centroid). Invertible for mapping results
        /// back to the original frame.
        public let transform: simd_float4x4
    }

    /// Aligns `mesh`'s long axis with +X by a rotation about Z, pivoting on the
    /// XY centroid of the top region.
    public static func normalized(_ mesh: TriangleMesh, topRegionMinHeight: Float = 0.8) -> Result {
        let axis = LongAxisPCA.longAxis(of: mesh, topRegionMinHeight: topRegionMinHeight)
        let phi = atan2(axis.y, axis.x)      // current heading of the long axis
        let alpha = -phi                      // rotate it onto +X

        // Pivot: XY centroid of the top region (fallback to all vertices).
        var pts = mesh.positions.filter { $0.z > topRegionMinHeight }
        if pts.count < 3 { pts = mesh.positions }
        var px = 0.0, py = 0.0
        for p in pts { px += Double(p.x); py += Double(p.y) }
        let count = Double(max(pts.count, 1))
        let pivot = SIMD2<Float>(Float(px / count), Float(py / count))

        let ca = cos(alpha), sa = sin(alpha)
        // Translation so the rotation pivots about `pivot`: t = p − R·p.
        let tx = pivot.x - (ca * pivot.x - sa * pivot.y)
        let ty = pivot.y - (sa * pivot.x + ca * pivot.y)

        let transform = simd_float4x4(
            SIMD4<Float>(ca, sa, 0, 0),   // column 0
            SIMD4<Float>(-sa, ca, 0, 0),  // column 1
            SIMD4<Float>(0, 0, 1, 0),     // column 2
            SIMD4<Float>(tx, ty, 0, 1)    // column 3 (translation)
        )
        return Result(mesh: mesh.transformed(by: transform), transform: transform)
    }
}
