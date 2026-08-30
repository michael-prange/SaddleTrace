import Foundation
import CoreVideo
import simd

/// A downsampled point cloud unprojected from a depth map, for the live 3D view.
/// Points are in camera space (metres); colors encode depth for shape legibility.
nonisolated struct DepthPointCloud: Sendable {
    var points: [SIMD3<Float>]
    var colors: [SIMD3<Float>]

    /// Unprojects a Float32 depth map using the (reference-scaled) intrinsics.
    ///
    /// - Parameters:
    ///   - depthMap: `kCVPixelFormatType_DepthFloat32` buffer.
    ///   - intrinsics: 3×3 camera intrinsics for `referenceDimensions`.
    ///   - referenceDimensions: the resolution the intrinsics were defined at.
    ///   - step: pixel stride (downsampling).
    ///   - range: valid depth band (metres).
    static func make(depthMap: CVPixelBuffer,
                     intrinsics: simd_float3x3,
                     referenceDimensions: CGSize,
                     step: Int = 4,
                     range: ClosedRange<Float> = 0.15...0.8) -> DepthPointCloud {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return DepthPointCloud(points: [], colors: [])
        }

        // Scale intrinsics from their reference dimensions to this depth map.
        let sx = Float(width) / Float(referenceDimensions.width)
        let sy = Float(height) / Float(referenceDimensions.height)
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        var points: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        points.reserveCapacity((width / step) * (height / step))
        colors.reserveCapacity(points.capacity)

        let lo = range.lowerBound, hi = range.upperBound
        var y = 0
        while y < height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            var x = 0
            while x < width {
                let d = row[x]
                if d.isFinite, d >= lo, d <= hi {
                    // Camera space: X right, Y down, Z forward. Flip for a
                    // SceneKit camera looking down −Z.
                    let px = (Float(x) - cx) * d / fx
                    let py = (Float(y) - cy) * d / fy
                    points.append(SIMD3<Float>(px, -py, -d))
                    colors.append(depthColor(d, lo: lo, hi: hi))
                }
                x += step
            }
            y += step
        }
        return DepthPointCloud(points: points, colors: colors)
    }

    /// Near = warm, far = cool, for surface shape legibility.
    private static func depthColor(_ d: Float, lo: Float, hi: Float) -> SIMD3<Float> {
        let t = max(0, min(1, (d - lo) / (hi - lo)))
        // Simple warm→cool ramp.
        return SIMD3<Float>(1 - t, 0.4 + 0.2 * sin(t * .pi), t)
    }
}
