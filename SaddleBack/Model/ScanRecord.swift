import Foundation

/// Which capture pipeline produced a scan (Design §6).
nonisolated enum CaptureMode: String, Codable, CaseIterable, Sendable {
    /// Rear LiDAR + wide-camera path (Pro devices).
    case lidar
    /// Front TrueDepth camera path (works on non-Pro devices).
    case trueDepth

    var displayName: String {
        switch self {
        case .lidar: "LiDAR (rear)"
        case .trueDepth: "TrueDepth (front)"
        }
    }
}

/// Photogrammetry detail level (Design §8.2). `.full` is macOS-only (Phase 2).
nonisolated enum ReconstructionDetail: String, Codable, CaseIterable, Sendable {
    case reduced, medium, raw, full
}

/// Lifecycle of a scan, driving the app's state machine and `ProcessingView`.
nonisolated enum ScanStatus: String, Codable, Sendable {
    case capturing
    case awaitingReconstruction
    case reconstructing
    case complete
    case failed

    var displayName: String {
        switch self {
        case .capturing: "Capturing"
        case .awaitingReconstruction: "Awaiting reconstruction"
        case .reconstructing: "Reconstructing"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }
}

/// A single scan session's metadata. Persisted as
/// `animals/{animalID}/scans/{id}/metadata.json` (Design §10). Bulk artifacts
/// (frames, meshes, exports) live alongside it on disk, addressed via
/// `ScanLibrary` URL helpers.
nonisolated struct ScanRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var timestamp: Date
    var captureMode: CaptureMode
    var detail: ReconstructionDetail
    var status: ScanStatus
    var deviceModel: String
    var osVersion: String
    /// Cross-section station spacing chosen for this scan (Design §9.2).
    var stationSpacingMeters: Double
    /// Wall-clock seconds the processing pipeline took, once complete.
    var processingSeconds: Double?

    init(id: UUID = UUID(),
         timestamp: Date = .now,
         captureMode: CaptureMode = .lidar,
         detail: ReconstructionDetail = .reduced,
         status: ScanStatus = .capturing,
         deviceModel: String = "",
         osVersion: String = "",
         stationSpacingMeters: Double = 0.1016,   // 4 inches (saddle-fitter default)
         processingSeconds: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.captureMode = captureMode
        self.detail = detail
        self.status = status
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.stationSpacingMeters = stationSpacingMeters
        self.processingSeconds = processingSeconds
    }

    /// Human-readable processing time, e.g. `"48 s"` or `"3m 12s"`.
    var processingSummary: String? {
        guard let s = processingSeconds else { return nil }
        if s < 60 { return String(format: "%.0f s", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
}
