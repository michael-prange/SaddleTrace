import Foundation
import ARKit
import CoreImage
import simd

/// JSON sidecar saved next to each frame (Design §6.2). Carries the world-space
/// camera pose and intrinsics that let `PhotogrammetrySession` reconstruct at
/// true metric scale (and, per §8.1, sidestep the folder-mode 17 Pro bug).
nonisolated struct FrameSidecar: Codable, Sendable {
    /// Column-major 4×4 world transform (16 floats).
    let cameraTransform: [Float]
    /// Column-major 3×3 intrinsics (9 floats).
    let cameraIntrinsics: [Float]
    let imageWidth: Double
    let imageHeight: Double
    let timestamp: Double

    init(transform: simd_float4x4, intrinsics: simd_float3x3,
         imageResolution: CGSize, timestamp: TimeInterval) {
        cameraTransform = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
        ]
        cameraIntrinsics = [
            intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z,
            intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z,
            intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z,
        ]
        imageWidth = imageResolution.width
        imageHeight = imageResolution.height
        self.timestamp = timestamp
    }
}

/// Persists a curated subset of the frame stream for later reconstruction
/// (Design §6.2). Selection triggers: angular change (>15°), translation (>5 cm),
/// or a 300 ms rate cap. Frames are only saved while tracking is `.normal`.
/// Runs on the AR session's (serial) delegate queue.
nonisolated final class FrameSnapshotter {
    private let directory: URL
    private let ciContext = CIContext()

    private var lastForward: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var lastSaveTime: TimeInterval = 0
    private(set) var savedCount = 0

    private let minAngleCos = Float(cos(15.0 * .pi / 180.0))
    private let minTranslation: Float = 0.05
    private let minInterval: TimeInterval = 0.3

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Considers a frame; if selected, writes it and returns the camera world
    /// position (so coverage can be credited). Returns nil when not saved.
    func consider(_ frame: ARFrame) -> SIMD3<Float>? {
        guard case .normal = frame.camera.trackingState else { return nil }
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)

        if lastPosition != nil, frame.timestamp - lastSaveTime < minInterval { return nil }

        var save = lastPosition == nil
        if let p = lastPosition, simd_distance(p, position) >= minTranslation { save = true }
        if let f = lastForward, simd_dot(f, forward) < minAngleCos { save = true }
        guard save else { return nil }

        write(frame, index: savedCount, transform: t)
        lastPosition = position
        lastForward = forward
        lastSaveTime = frame.timestamp
        savedCount += 1
        return position
    }

    private func write(_ frame: ARFrame, index: Int, transform: simd_float4x4) {
        let base = String(format: "%04d", index)

        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            try? ciContext.writeHEIFRepresentation(
                of: image, to: directory.appendingPathComponent("\(base).heic"),
                format: .RGBA8, colorSpace: space)
        }

        if let depth = frame.sceneDepth?.depthMap {
            writeDepth(depth, to: directory.appendingPathComponent("\(base).depth"))
        }

        let sidecar = FrameSidecar(
            transform: transform, intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution, timestamp: frame.timestamp)
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: directory.appendingPathComponent("\(base).json"))
        }
    }

    /// Raw Float32 depth: two `UInt32` (width, height) header, then row-major values.
    private func writeDepth(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var out = Data()
        let header = [UInt32(w), UInt32(h)]
        header.withUnsafeBytes { out.append(contentsOf: $0) }
        let rowLen = w * MemoryLayout<Float32>.size
        for y in 0..<h {
            out.append(Data(bytes: base.advanced(by: y * rowBytes), count: rowLen))
        }
        try? out.write(to: url)
    }
}
