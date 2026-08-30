import Foundation
import RealityKit

/// Maps the app's detail setting to a photogrammetry detail level. This iOS SDK
/// only exposes `.reduced` (higher levels are macOS-only, §8.2), so all map there
/// for now; `.reduced` is the recommended on-device default regardless.
extension ReconstructionDetail {
    var photogrammetryDetail: PhotogrammetrySession.Request.Detail { .reduced }
}

/// Runs on-device photogrammetry (`PhotogrammetrySession`) over a folder of
/// captured frames to produce a USDZ mesh (Design §8). Metric scale comes from
/// depth embedded in the HEICs (TrueDepth path).
enum ReconstructionDriver {

    enum ReconstructionError: Error, Equatable {
        case unsupported
        case noFrames
        case failed(String)
    }

    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    /// Reconstructs a USDZ at `outputURL` from the HEICs in `framesDirectory`,
    /// reporting fractional progress. Uses a hard-linked images-only temp folder
    /// so non-image sidecars don't confuse the session.
    static func reconstruct(
        framesDirectory: URL, outputURL: URL, detail: ReconstructionDetail,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard PhotogrammetrySession.isSupported else { throw ReconstructionError.unsupported }

        let fm = FileManager.default
        let heics = ((try? fm.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
        guard !heics.isEmpty else { throw ReconstructionError.noFrames }

        let imagesDir = framesDirectory.appendingPathComponent("_images", isDirectory: true)
        try? fm.removeItem(at: imagesDir)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        for heic in heics {
            try? fm.linkItem(at: heic, to: imagesDir.appendingPathComponent(heic.lastPathComponent))
        }
        defer { try? fm.removeItem(at: imagesDir) }

        let session = try PhotogrammetrySession(input: imagesDir)
        let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: detail.photogrammetryDetail)
        try session.process(requests: [request])

        // Cancel if it hangs (low-texture coats can stall SfM indefinitely).
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            session.cancel()
        }
        defer { timeout.cancel() }

        for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .processingComplete:
                return outputURL
            case .processingCancelled:
                throw ReconstructionError.failed("Reconstruction timed out after 5 minutes.")
            case .requestError(_, let error):
                throw ReconstructionError.failed(error.localizedDescription)
            default:
                break
            }
        }
        throw ReconstructionError.failed("Session ended without producing a model.")
    }
}
