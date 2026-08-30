import Foundation
import ARKit
import CoreImage
import CoreVideo
import simd

/// Persists the raw inputs of a single LiDAR shot — the photo, depth map,
/// confidence map, and camera intrinsics/pose — so the whole `DepthGridMesh`
/// build (geometry *and* paint) can be re-run later with improved code. This is
/// what lets code improvements be applied to the entire archive.
///
/// Files written into a scan's `frames/`: `photo.heic`, `depth.bin`,
/// `confidence.bin`, `shot.json`.
nonisolated enum RawShotWriter {

    /// Sendable snapshot extracted from an ARFrame (extract on the main actor,
    /// then persist off-main).
    struct RawShot: Sendable {
        let photoHEIC: Data?
        let depth: [Float]
        let confidence: [UInt8]
        let depthW: Int
        let depthH: Int
        /// The confidence map's OWN dimensions. Usually equal to the depth map's,
        /// but they are separate buffers — writing depth dims into the confidence
        /// header would silently mis-shape the array on read-back.
        let confW: Int
        let confH: Int
        let intrinsics: [Float]        // column-major 3×3
        let imageWidth: Double
        let imageHeight: Double
        let transform: [Float]         // column-major 4×4 (camera → world)
    }

    struct Sidecar: Codable {
        let intrinsics: [Float]
        let imageWidth: Double
        let imageHeight: Double
        let cameraTransform: [Float]
        let depthWidth: Int
        let depthHeight: Int
    }

    private static let ciContext = CIContext(options: nil)

    /// Reads the frame's buffers + calibration into Sendable arrays and encodes the
    /// photo to HEIC. Call where the `ARFrame` is valid (the AR/main context).
    static func extract(from frame: ARFrame) -> RawShot {
        var heic: Data?
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            heic = ciContext.heifRepresentation(of: CIImage(cvPixelBuffer: frame.capturedImage),
                                                format: .RGBA8, colorSpace: space)
        }

        var depth: [Float] = [], confidence: [UInt8] = []
        var dw = 0, dh = 0
        var cw = 0, ch = 0
        if let sd = frame.sceneDepth {
            let dm = sd.depthMap
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            dw = CVPixelBufferGetWidth(dm); dh = CVPixelBufferGetHeight(dm)
            if let base = CVPixelBufferGetBaseAddress(dm) {
                let row = CVPixelBufferGetBytesPerRow(dm)
                depth = [Float](repeating: 0, count: dw * dh)
                for y in 0..<dh {
                    let p = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
                    for x in 0..<dw { depth[y * dw + x] = p[x] }
                }
            }
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)

            if let cm = sd.confidenceMap {
                CVPixelBufferLockBaseAddress(cm, .readOnly)
                cw = CVPixelBufferGetWidth(cm); ch = CVPixelBufferGetHeight(cm)
                if let base = CVPixelBufferGetBaseAddress(cm) {
                    let row = CVPixelBufferGetBytesPerRow(cm)
                    confidence = [UInt8](repeating: 0, count: cw * ch)
                    for y in 0..<ch {
                        let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<cw { confidence[y * cw + x] = p[x] }
                    }
                }
                CVPixelBufferUnlockBaseAddress(cm, .readOnly)
            }
        }

        let k = frame.camera.intrinsics
        let t = frame.camera.transform
        let res = frame.camera.imageResolution
        return RawShot(
            photoHEIC: heic, depth: depth, confidence: confidence,
            depthW: dw, depthH: dh, confW: cw, confH: ch,
            intrinsics: [k.columns.0.x, k.columns.0.y, k.columns.0.z,
                         k.columns.1.x, k.columns.1.y, k.columns.1.z,
                         k.columns.2.x, k.columns.2.y, k.columns.2.z],
            imageWidth: res.width, imageHeight: res.height,
            transform: [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
                        t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
                        t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
                        t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w])
    }

    static func persist(_ shot: RawShot, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let heic = shot.photoHEIC { try? heic.write(to: dir.appendingPathComponent("photo.heic")) }

        if !shot.depth.isEmpty {
            var data = Data()
            var w = UInt32(shot.depthW), h = UInt32(shot.depthH)
            withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
            shot.depth.withUnsafeBytes { data.append(contentsOf: $0) }
            try? data.write(to: dir.appendingPathComponent("depth.bin"))
        }
        if !shot.confidence.isEmpty {
            var data = Data()
            var w = UInt32(shot.confW), h = UInt32(shot.confH)
            withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
            data.append(contentsOf: shot.confidence)
            try? data.write(to: dir.appendingPathComponent("confidence.bin"))
        }

        let sidecar = Sidecar(intrinsics: shot.intrinsics, imageWidth: shot.imageWidth,
                              imageHeight: shot.imageHeight, cameraTransform: shot.transform,
                              depthWidth: shot.depthW, depthHeight: shot.depthH)
        if let json = try? JSONEncoder().encode(sidecar) {
            try? json.write(to: dir.appendingPathComponent("shot.json"))
        }
    }
}
