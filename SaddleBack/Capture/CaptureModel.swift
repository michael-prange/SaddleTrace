import Foundation
import ARKit
import Observation
import UIKit

/// Where the phone is relative to the ideal scanning distance band.
nonisolated enum CaptureDistanceState: String, Sendable {
    case noSurface
    case tooClose
    case justRight
    case tooFar
}

/// Observable state for the capture screen: live distance-to-surface, its
/// classification, and tracking quality. Drives the distance HUD and haptics.
/// Design §6.2–§6.3 working distance (40–80 cm for the LiDAR mode).
@MainActor
@Observable
final class CaptureModel {
    /// Distance from the device to the surface at the frame centre, in metres.
    var distanceMeters: Double?
    var state: CaptureDistanceState = .noSurface
    var isTrackingNormal = false

    /// Fraction of the scanned surface that is fully covered (green), 0–1.
    var coverageFraction: Double = 0
    /// Number of frames saved so far for reconstruction.
    var savedFrameCount = 0

    /// Whether this device can do LiDAR scene reconstruction at all.
    let isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    /// Set by the capture view (via the AR coordinator): requests the fused LiDAR
    /// mesh be written to the given URL on the next AR frame.
    var requestMeshExport: ((URL) -> Void)?
    /// Result of that export (nil = not yet requested / still pending).
    var meshExportFinished: Bool?

    /// Ideal band edges (metres).
    let nearLimit = 0.40
    let farLimit = 0.80

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private var lastHaptic = Date.distantPast

    init() { impact.prepare() }

    /// Feeds a new distance sample (already reduced from the depth map) and the
    /// tracking state. Called ~10 Hz from the AR session delegate.
    func update(distance: Double?, trackingNormal: Bool) {
        isTrackingNormal = trackingNormal
        distanceMeters = distance
        state = classify(distance)
        emitHapticIfNeeded()
    }

    private func classify(_ d: Double?) -> CaptureDistanceState {
        guard let d else { return .noSurface }
        if d < nearLimit { return .tooClose }
        if d > farLimit { return .tooFar }
        return .justRight
    }

    /// A quiet tick that quickens as you leave the ideal band, and a firmer one
    /// while out of range.
    private func emitHapticIfNeeded() {
        guard let d = distanceMeters else { return }
        let outOfRange = d < nearLimit || d > farLimit
        let approaching = (d >= nearLimit && d < nearLimit + 0.05)
            || (d <= farLimit && d > farLimit - 0.05)

        let interval: TimeInterval = outOfRange ? 0.4 : (approaching ? 0.9 : .infinity)
        guard interval.isFinite else { return }

        let now = Date()
        guard now.timeIntervalSince(lastHaptic) >= interval else { return }
        impact.impactOccurred(intensity: outOfRange ? 0.7 : 0.4)
        impact.prepare()
        lastHaptic = now
    }
}
