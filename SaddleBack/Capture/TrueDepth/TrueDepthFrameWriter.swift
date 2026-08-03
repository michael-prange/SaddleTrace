import Foundation
import AVFoundation
import CoreImage
import CoreMotion
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import simd

/// Sidecar saved beside each front-camera frame (Design §6.6.1). No world pose is
/// available on the front camera, so attitude/gravity come from CoreMotion; the
/// depth is metric, giving scale for reconstruction.
nonisolated struct TrueDepthSidecar: Codable, Sendable {
    let depthIntrinsics: [Float]           // column-major 3×3
    let depthReferenceWidth: Double
    let depthReferenceHeight: Double
    let attitudeQuaternion: [Double]        // x, y, z, w
    let gravity: [Double]                   // x, y, z
    let timestamp: Double
}

/// Writes front-camera frames (RGB HEIC + Float32 depth + sidecar) to disk.
nonisolated final class TrueDepthFrameWriter {
    private let directory: URL
    private let ciContext = CIContext()
    private(set) var savedCount = 0

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(rgb: CVPixelBuffer, depthData: AVDepthData,
               intrinsics: simd_float3x3, referenceDimensions: CGSize,
               attitude: CMQuaternion, gravity: CMAcceleration, timestamp: Double) {
        let base = String(format: "%04d", savedCount)

        // HEIC with embedded depth — gives PhotogrammetrySession metric scale.
        writeHEICWithDepth(rgb: rgb, depthData: depthData,
                           to: directory.appendingPathComponent("\(base).heic"))

        let sidecar = TrueDepthSidecar(
            depthIntrinsics: [
                intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z,
                intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z,
                intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z,
            ],
            depthReferenceWidth: referenceDimensions.width,
            depthReferenceHeight: referenceDimensions.height,
            attitudeQuaternion: [attitude.x, attitude.y, attitude.z, attitude.w],
            gravity: [gravity.x, gravity.y, gravity.z],
            timestamp: timestamp)
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: directory.appendingPathComponent("\(base).json"))
        }
        savedCount += 1
    }

    /// Fallback when depth is unavailable: save the RGB frame (plain HEIC) plus a
    /// sidecar. No metric scale, but the frames are preserved for later use.
    func writeRGBOnly(rgb: CVPixelBuffer, attitude: CMQuaternion, gravity: CMAcceleration, timestamp: Double) {
        let base = String(format: "%04d", savedCount)
        let image = CIImage(cvPixelBuffer: rgb)
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            try? ciContext.writeHEIFRepresentation(
                of: image, to: directory.appendingPathComponent("\(base).heic"),
                format: .RGBA8, colorSpace: space)
        }
        let sidecar = TrueDepthSidecar(
            depthIntrinsics: [], depthReferenceWidth: 0, depthReferenceHeight: 0,
            attitudeQuaternion: [attitude.x, attitude.y, attitude.z, attitude.w],
            gravity: [gravity.x, gravity.y, gravity.z], timestamp: timestamp)
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: directory.appendingPathComponent("\(base).json"))
        }
        savedCount += 1
    }

    /// Writes an HEIC with the depth map embedded as auxiliary data, so
    /// downstream photogrammetry recovers real-world scale.
    private func writeHEICWithDepth(rgb: CVPixelBuffer, depthData: AVDepthData, to url: URL) {
        guard let cgImage = ciContext.createCGImage(CIImage(cvPixelBuffer: rgb),
                                                    from: CIImage(cvPixelBuffer: rgb).extent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return }

        CGImageDestinationAddImage(destination, cgImage, nil)

        var auxDataType: NSString?
        if let auxInfo = depthData.dictionaryRepresentation(forAuxiliaryDataType: &auxDataType),
           let auxDataType {
            CGImageDestinationAddAuxiliaryDataInfo(destination, auxDataType as CFString, auxInfo as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
    }
}
