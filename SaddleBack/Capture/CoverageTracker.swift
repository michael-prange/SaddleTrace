import Foundation
import simd

/// How well a region of the surface has been captured (Design §6.3). Maps to the
/// red → yellow → green paint and to per-face material indices for rendering.
nonisolated enum CoverageState: Int, Sendable {
    case uncovered = 0   // red
    case partial = 1     // yellow
    case covered = 2     // green

    /// Material index for the coverage-colored mesh (red / yellow / green).
    var materialIndex: UInt32 { UInt32(rawValue) }

    /// RGB (0–1) for point-cloud coloring: red / yellow / green.
    var rgb: SIMD3<Float> {
        switch self {
        case .uncovered: SIMD3<Float>(1.0, 0.18, 0.18)
        case .partial: SIMD3<Float>(1.0, 0.85, 0.1)
        case .covered: SIMD3<Float>(0.2, 0.9, 0.25)
        }
    }
}

/// Tracks how well each part of the scanned surface has been viewed, accumulating
/// "good views" from saved snapshots (Design §6.3).
///
/// Coverage is keyed by a **voxel** of the face centroid rather than a mesh face
/// index, so it survives ARKit re-tessellating the scene mesh between updates —
/// a face's coverage persists even as the triangle it belongs to changes.
/// Pure value logic (no ARKit types), so it is unit-testable off-device.
nonisolated final class CoverageTracker {

    struct Thresholds: Sendable {
        /// Good views to reach `.partial`.
        var partial = 2
        /// Good views to reach `.covered`.
        var covered = 5
        /// A face counts as "well viewed" only within this distance band (m).
        var minDistance = 0.30
        var maxDistance = 1.00
        /// …and only when the face normal is within this angle of the camera ray.
        var maxAngleDegrees = 45.0
        /// Coverage voxel edge length (m).
        var voxelSize = 0.03
        init() {}
    }

    let thresholds: Thresholds
    private var goodViews: [SIMD3<Int>: Int] = [:]

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    private func voxel(_ p: SIMD3<Float>) -> SIMD3<Int> {
        let s = Float(thresholds.voxelSize)
        return SIMD3<Int>(Int((p.x / s).rounded(.down)),
                          Int((p.y / s).rounded(.down)),
                          Int((p.z / s).rounded(.down)))
    }

    /// Registers a saved snapshot: for each mesh face visible from `cameraPosition`
    /// within the distance band and view angle, credit its voxel one good view.
    func registerSnapshot(faces: [(centroid: SIMD3<Float>, normal: SIMD3<Float>)],
                          cameraPosition: SIMD3<Float>) {
        let cosLimit = Float(cos(thresholds.maxAngleDegrees * .pi / 180))
        let minD = Float(thresholds.minDistance), maxD = Float(thresholds.maxDistance)

        for face in faces {
            let toFace = face.centroid - cameraPosition
            let dist = simd_length(toFace)
            guard dist >= minD, dist <= maxD else { continue }

            // Angle between the face normal and the ray from the face to the camera.
            let n = simd_normalize(face.normal)
            let toCamera = simd_normalize(-toFace)
            guard simd_dot(n, toCamera) >= cosLimit else { continue }

            goodViews[voxel(face.centroid), default: 0] += 1
        }
    }

    /// Coverage state at a surface point.
    func state(at point: SIMD3<Float>) -> CoverageState {
        let count = goodViews[voxel(point)] ?? 0
        if count >= thresholds.covered { return .covered }
        if count >= thresholds.partial { return .partial }
        return .uncovered
    }

    /// Overall progress: fraction of touched voxels that are fully covered, plus
    /// the covered/total voxel counts. Used for the capture HUD and auto-stop.
    var progress: (fraction: Double, covered: Int, total: Int) {
        let total = goodViews.count
        guard total > 0 else { return (0, 0, 0) }
        let threshold = thresholds.covered
        let covered = goodViews.values.lazy.filter { $0 >= threshold }.count
        return (Double(covered) / Double(total), covered, total)
    }
}
