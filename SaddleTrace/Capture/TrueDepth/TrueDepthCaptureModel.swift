import Foundation
import Observation
import UIKit

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

    private let impact = UIImpactFeedbackGenerator(style: .light)

    init() { impact.prepare() }

    func classify(_ d: Double?) -> CaptureDistanceState {
        guard let d else { return .noSurface }
        if d < nearLimit { return .tooClose }
        if d > farLimit { return .tooFar }
        return .justRight
    }

    /// Applies a capture sample from the controller and emits a light haptic tick
    /// for each newly saved frame while scanning — tactile proof it's working.
    func apply(distance: Double?, scanning: Bool, savedFrames: Int) {
        distanceMeters = distance
        state = classify(distance)
        isScanning = scanning
        if scanning, savedFrames > savedFrameCount {
            impact.impactOccurred(intensity: 0.5)
            impact.prepare()
        }
        savedFrameCount = savedFrames
    }
}
