import Foundation
import ARKit
import simd
import MeshKit

/// Builds a dense surface mesh + point cloud from a SINGLE ARKit LiDAR frame by
/// unprojecting the scene-depth map and triangulating the pixel grid. This is the
/// robust "depth photograph" primitive: one instant, no sweeping, no fusion, no
/// tracking drift. Output is in ARKit world coordinates (Y-up).
nonisolated enum DepthGridMesh {

    struct Result: Sendable {
        let mesh: TriangleMesh          // world coords (ARKit Y-up)
        let points: [SIMD3<Float>]      // world coords
        let colors: [SIMD3<Float>]      // confidence colors (green high / yellow medium)
    }

    /// - Parameters:
    ///   - maxDepth: drop pixels farther than this (m) — trims the background.
    ///   - maxEdgeJump: don't connect a quad whose corner depths span more than
    ///     this (m) — keeps the back from bridging to the ground at its edges.
    static func build(from frame: ARFrame, maxDepth: Float = 1.5,
                      maxEdgeJump: Float = 0.04) -> Result? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let confMap = sceneDepth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confMap { CVPixelBufferLockBaseAddress(confMap, .readOnly) }
        defer { if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) } }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confBase = confMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = confMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // Intrinsics scaled from the captured-image resolution to the depth map's.
        let img = frame.camera.imageResolution
        let K = frame.camera.intrinsics
        let sx = Float(w) / Float(img.width), sy = Float(h) / Float(img.height)
        let fx = K.columns.0.x * sx, fy = K.columns.1.y * sy
        let cx = K.columns.2.x * sx, cy = K.columns.2.y * sy
        let cam = frame.camera.transform

        func depth(_ x: Int, _ y: Int) -> Float {
            depthBase.advanced(by: y * depthRow).assumingMemoryBound(to: Float32.self)[x]
        }
        func confidence(_ x: Int, _ y: Int) -> UInt8 {
            guard let confBase else { return 2 }
            return confBase.advanced(by: y * confRow).assumingMemoryBound(to: UInt8.self)[x]
        }

        // Unproject valid pixels to world; remember each pixel's vertex index.
        var vertexIndex = [Int32](repeating: -1, count: w * h)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        for y in 0..<h {
            for x in 0..<w {
                let d = depth(x, y)
                guard d.isFinite, d > 0.1, d <= maxDepth else { continue }
                guard confidence(x, y) >= 1 else { continue }   // drop low confidence
                // CV camera frame (x right, y down, z forward) → ARKit camera frame
                // (x right, y up, z toward viewer): flip y and z.
                let px = (Float(x) - cx) * d / fx
                let py = (Float(y) - cy) * d / fy
                let world = cam * SIMD4<Float>(px, -py, -d, 1)
                vertexIndex[y * w + x] = Int32(positions.count)
                positions.append(SIMD3<Float>(world.x, world.y, world.z))
                colors.append(confidence(x, y) >= 2
                              ? SIMD3<Float>(0.2, 0.9, 0.25)     // high → green
                              : SIMD3<Float>(1.0, 0.85, 0.1))    // medium → yellow
            }
        }
        guard positions.count >= 3 else { return nil }

        // Triangulate the grid; emit a quad only if all four corners are valid and
        // their depth spread is small (don't span depth discontinuities).
        var indices: [UInt32] = []
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let a = vertexIndex[y * w + x], b = vertexIndex[y * w + x + 1]
                let c = vertexIndex[(y + 1) * w + x], e = vertexIndex[(y + 1) * w + x + 1]
                guard a >= 0, b >= 0, c >= 0, e >= 0 else { continue }
                let da = depth(x, y), db = depth(x + 1, y), dc = depth(x, y + 1), de = depth(x + 1, y + 1)
                let lo = min(min(da, db), min(dc, de)), hi = max(max(da, db), max(dc, de))
                guard hi - lo <= maxEdgeJump else { continue }
                indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b)])
                indices.append(contentsOf: [UInt32(b), UInt32(c), UInt32(e)])
            }
        }
        guard indices.count >= 3 else { return nil }

        return Result(mesh: TriangleMesh(positions: positions, indices: indices),
                      points: positions, colors: colors)
    }
}
