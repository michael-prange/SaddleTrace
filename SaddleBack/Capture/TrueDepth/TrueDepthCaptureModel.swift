import Foundation
import Observation

/// Observable state for the front TrueDepth capture screen. The working distance
/// band is closer than LiDAR (Design §6.6.2: ~25–45 cm). Scanning **auto-starts**
/// when the phone is face-down over the back and a surface is in range.
@MainActor
@Observable
final class TrueDepthCaptureModel {
    var isSupported = CaptureCapabilities.hasTrueDepth
    var isAuthorized = false

    var distanceMeters: Double?
    var state: CaptureDistanceState = .noSurface
    /// Whether the phone is held screen-down (ready to scan).
    var isFaceDown = false
    /// Whether capture has auto-started.
    var isScanning = false
    var savedFrameCount = 0

    let nearLimit = 0.25
    let farLimit = 0.45

    func classify(_ d: Double?) -> CaptureDistanceState {
        guard let d else { return .noSurface }
        if d < nearLimit { return .tooClose }
        if d > farLimit { return .tooFar }
        return .justRight
    }
}
