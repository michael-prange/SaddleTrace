import Foundation
import ARKit
import simd
import MeshKit
import CoreVideo

/// Builds a dense surface mesh + point cloud from a SINGLE ARKit LiDAR frame by
/// unprojecting the scene-depth map and triangulating the pixel grid. This is the
/// robust "depth photograph" primitive: one instant, no sweeping, no fusion, no
/// tracking drift. Output is in ARKit world coordinates (Y-up).
nonisolated enum DepthGridMesh {

    struct Result: Sendable {
        let mesh: TriangleMesh          // world coords (ARKit Y-up)
        let points: [SIMD3<Float>]      // world coords
        let colors: [SIMD3<Float>]      // confidence colors (green high / yellow medium)
        let photoColors: [SIMD3<Float>] // per-vertex color sampled from the photo
    }

    /// - Parameters:
    ///   - maxDepth: drop pixels farther than this (m) — trims the background.
    ///   - maxEdgeJump: don't connect a quad whose corner depths span more than
    ///     this (m) — keeps the back from bridging to the ground at its edges.
    static func build(from frame: ARFrame, maxDepth: Float = 1.5,
                      maxEdgeJump: Float = 0.04, dropBelowCrest: Float = 0.35) -> Result? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let confMap = sceneDepth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confMap { CVPixelBufferLockBaseAddress(confMap, .readOnly) }
        defer { if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) } }

        // The captured photo shares the depth map's orientation (both CVPixelBuffers,
        // row 0 = top), so we sample it DIRECTLY — no CIImage/CGContext flip, which
        // is what was mirroring the paint relative to the geometry.
        let photo = frame.capturedImage
        CVPixelBufferLockBaseAddress(photo, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(photo, .readOnly) }

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

        // 420 YCbCr bi-planar accessors for the captured photo (plane 0 = luma,
        // plane 1 = interleaved Cb/Cr at half resolution).
        let lumaW = CVPixelBufferGetWidthOfPlane(photo, 0)
        let lumaH = CVPixelBufferGetHeightOfPlane(photo, 0)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(photo, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(photo, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(photo, 1)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(photo, 1)
        let videoRange = CVPixelBufferGetPixelFormatType(photo) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        func photoColor(_ x: Int, _ y: Int) -> SIMD3<Float> {
            guard let yBase, let cBase, lumaW > 0, lumaH > 0 else { return SIMD3<Float>(0.7, 0.7, 0.7) }
            // Depth pixel → luma pixel; both buffers are row-0-top, same orientation.
            let rx = min(x * lumaW / w, lumaW - 1)
            let ry = min(y * lumaH / h, lumaH - 1)
            let yv = Float(yBase.advanced(by: ry * yRow + rx).assumingMemoryBound(to: UInt8.self).pointee)
            let cx = min(rx / 2, lumaW / 2 - 1), cy = min(ry / 2, lumaH / 2 - 1)
            let cptr = cBase.advanced(by: cy * cRow + cx * 2).assumingMemoryBound(to: UInt8.self)
            let cb = Float(cptr[0]) - 128, cr = Float(cptr[1]) - 128
            // BT.601 YCbCr → RGB (video- or full-range).
            let yn = videoRange ? (yv - 16) * 1.164 : yv
            let r = yn + 1.402 * cr
            let g = yn - 0.344136 * cb - 0.714136 * cr
            let b = yn + 1.772 * cb
            func clamp(_ v: Float) -> Float { min(max(v / 255, 0), 1) }
            return SIMD3<Float>(clamp(r), clamp(g), clamp(b))
        }

        // 1. Gather valid depths (0 = invalid): finite, in range, confidence ≥ medium.
        var raw = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = depth(x, y)
                if d.isFinite, d > 0.1, d <= maxDepth, confidence(x, y) >= 1 {
                    raw[y * w + x] = d
                }
            }
        }

        // 2. 3×3 median filter over valid neighbours — removes per-pixel depth
        //    noise (smoother sections/surface) without bridging holes.
        var filt = raw
        var nb: [Float] = []; nb.reserveCapacity(9)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where raw[y * w + x] > 0 {
                nb.removeAll(keepingCapacity: true)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let v = raw[(y + dy) * w + (x + dx)]
                        if v > 0 { nb.append(v) }
                    }
                }
                if nb.count >= 3 { nb.sort(); filt[y * w + x] = nb[nb.count / 2] }
            }
        }

        // 3. Unproject valid (filtered) pixels to world; remember each pixel's index.
        var vertexIndex = [Int32](repeating: -1, count: w * h)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var photoColors: [SIMD3<Float>] = []
        for y in 0..<h {
            for x in 0..<w where filt[y * w + x] > 0 {
                let d = filt[y * w + x]
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
                photoColors.append(photoColor(x, y))
            }
        }
        guard positions.count >= 3 else { return nil }

        // 3b. Height clip: the world is gravity-aligned (Y = up), and the back is
        //     the highest surface in view. Drop everything more than `dropBelowCrest`
        //     below the crest — that's below the ±8" saddle band but well above the
        //     ground, so pasture grass (which the barrel-to-ground slope would
        //     otherwise bridge into one connected mesh) is excluded.
        let sortedY = positions.map { $0.y }.sorted()
        let topY = sortedY[Int(Double(sortedY.count - 1) * 0.98)]   // robust crest
        let cutoffY = topY - dropBelowCrest
        for p in 0..<vertexIndex.count {
            let vi = vertexIndex[p]
            if vi >= 0, positions[Int(vi)].y < cutoffY { vertexIndex[p] = -1 }
        }

        // 4. Triangulate the grid (skip quads spanning a depth discontinuity) while
        //    union-finding connected vertices.
        var parent = Array(0..<positions.count)
        func find(_ a: Int) -> Int { var r = a; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }

        var indices: [UInt32] = []
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let a = vertexIndex[y * w + x], b = vertexIndex[y * w + x + 1]
                let c = vertexIndex[(y + 1) * w + x], e = vertexIndex[(y + 1) * w + x + 1]
                guard a >= 0, b >= 0, c >= 0, e >= 0 else { continue }
                let da = filt[y * w + x], db = filt[y * w + x + 1]
                let dc = filt[(y + 1) * w + x], de = filt[(y + 1) * w + x + 1]
                let lo = min(min(da, db), min(dc, de)), hi = max(max(da, db), max(dc, de))
                guard hi - lo <= maxEdgeJump else { continue }
                let ai = Int(a), bi = Int(b), ci = Int(c), ei = Int(e)
                union(ai, bi); union(ai, ci); union(ai, ei)
                indices.append(contentsOf: [UInt32(ai), UInt32(ci), UInt32(bi)])
                indices.append(contentsOf: [UInt32(bi), UInt32(ci), UInt32(ei)])
            }
        }
        guard indices.count >= 3 else { return nil }

        // 5. Keep only the LARGEST connected component — drops the arm, ground
        //    bits, and every disconnected outlier from both mesh and cloud.
        var size = [Int](repeating: 0, count: positions.count)
        for i in 0..<positions.count { size[find(i)] += 1 }
        var bestRoot = 0
        for r in 1..<positions.count where size[r] > size[bestRoot] { bestRoot = r }

        var remap = [Int32](repeating: -1, count: positions.count)
        var keptPositions: [SIMD3<Float>] = []
        var keptColors: [SIMD3<Float>] = []
        var keptPhoto: [SIMD3<Float>] = []
        for i in 0..<positions.count where find(i) == bestRoot {
            remap[i] = Int32(keptPositions.count)
            keptPositions.append(positions[i]); keptColors.append(colors[i]); keptPhoto.append(photoColors[i])
        }
        var keptIndices: [UInt32] = []
        var t = 0
        while t < indices.count {
            let a = remap[Int(indices[t])], b = remap[Int(indices[t + 1])], c = remap[Int(indices[t + 2])]
            if a >= 0, b >= 0, c >= 0 { keptIndices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)]) }
            t += 3
        }
        guard keptIndices.count >= 3 else { return nil }

        return Result(mesh: TriangleMesh(positions: keptPositions, indices: keptIndices),
                      points: keptPositions, colors: keptColors, photoColors: keptPhoto)
    }
}
