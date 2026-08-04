import Foundation
import ARKit
import simd
import MeshKit
import CoreImage
import CoreGraphics

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

    private static let ciContext = CIContext(options: nil)

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

        // Render the captured photo to a top-row-first RGBA8 bitmap so each depth
        // pixel can be colored from the matching image pixel (same camera → aligned).
        var rgb: [UInt8]?
        var rgbW = 0, rgbH = 0
        let ci = CIImage(cvPixelBuffer: frame.capturedImage)
        if let cg = DepthGridMesh.ciContext.createCGImage(ci, from: ci.extent) {
            rgbW = cg.width; rgbH = cg.height
            var buf = [UInt8](repeating: 0, count: rgbW * rgbH * 4)
            buf.withUnsafeMutableBytes { ptr in
                if let ctx = CGContext(data: ptr.baseAddress, width: rgbW, height: rgbH, bitsPerComponent: 8,
                                       bytesPerRow: rgbW * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.translateBy(x: 0, y: CGFloat(rgbH)); ctx.scaleBy(x: 1, y: -1)   // row 0 = image top
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rgbW, height: rgbH))
                }
            }
            rgb = buf
        }
        func photoColor(_ x: Int, _ y: Int) -> SIMD3<Float> {
            guard let rgb, rgbW > 0, rgbH > 0 else { return SIMD3<Float>(0.7, 0.7, 0.7) }
            let rx = min(x * rgbW / w, rgbW - 1), ry = min(y * rgbH / h, rgbH - 1)
            let i = (ry * rgbW + rx) * 4
            return SIMD3<Float>(Float(rgb[i]) / 255, Float(rgb[i + 1]) / 255, Float(rgb[i + 2]) / 255)
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
