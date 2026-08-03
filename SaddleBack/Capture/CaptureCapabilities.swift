import Foundation
import ARKit
import AVFoundation

/// The user's preferred capture camera (Settings). `auto` picks the best for the
/// device: rear LiDAR on Pro models, front TrueDepth otherwise.
nonisolated enum CaptureCameraPreference: String, CaseIterable, Sendable, Identifiable {
    case auto
    case front
    case rear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .front: "Front (TrueDepth)"
        case .rear: "Rear (LiDAR)"
        }
    }
}

/// Device capture capabilities and mode resolution.
nonisolated enum CaptureCapabilities {
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    static var hasTrueDepth: Bool {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    /// Resolves the capture mode to use for a new scan given the user's
    /// preference and the device's cameras.
    static func resolvedMode(preference: CaptureCameraPreference) -> CaptureMode? {
        switch preference {
        case .front: return hasTrueDepth ? .trueDepth : (hasLiDAR ? .lidar : nil)
        case .rear: return hasLiDAR ? .lidar : (hasTrueDepth ? .trueDepth : nil)
        case .auto: return hasLiDAR ? .lidar : (hasTrueDepth ? .trueDepth : nil)
        }
    }
}
