import Foundation
@preconcurrency import AVFoundation
import CoreMotion
import CoreVideo
import simd

/// Drives the front TrueDepth camera: synchronized RGB + depth capture, a live
/// point cloud, CoreMotion attitude, face-down auto-start, and frame saving
/// (Design §6.6). Session/data work runs on background queues; UI updates hop to
/// the main actor.
// `@unchecked Sendable` is required and correct here (not just a convenience):
// this type is an `@objc` AVFoundation delegate — so it can't be an actor — and
// it dispatches `self` onto its own serial `sessionQueue`/`dataQueue`. The
// compiler can't prove the resulting queue-confinement, so we assert it: all
// capture state is mutated only on the serial data queue; cross-queue fields are
// `nonisolated(unsafe)` and set once before frames flow.
nonisolated final class TrueDepthCaptureController: NSObject, AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable {

    private let model: TrueDepthCaptureModel

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "saddleback.truedepth.session")
    private let dataQueue = DispatchQueue(label: "saddleback.truedepth.data")
    private let motionQueue = OperationQueue()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let motion = CMMotionManager()

    private var writer: TrueDepthFrameWriter?
    private var scanning = false
    private var lastSave = 0.0
    private var lastCloud = 0.0
    /// Set from the UI to force scanning to begin even if auto-start conditions
    /// aren't met (reliability fallback).
    nonisolated(unsafe) var manualStartRequested = false

    /// Force capture to start now.
    func requestStart() { manualStartRequested = true }

    // Working-distance band (m); mirrors TrueDepthCaptureModel for the data queue.
    private static let nearLimit = 0.25
    private static let farLimit = 0.45

    // Auto-start is deliberately looser than the working-distance band: the fitter
    // usually holds the phone tilted over the back rather than perfectly flat, and
    // at a range that varies. Accept more tilt and a wider distance so it fires;
    // the manual Start button remains the reliable primary path.
    private static let autoStartGravityZ = 0.5
    private static let autoStartNear = 0.20
    private static let autoStartFar = 0.60

    /// Set by `PointCloudSceneView`; called on the main actor.
    nonisolated(unsafe) weak var renderer: (any PointCloudRendering)?

    init(model: TrueDepthCaptureModel) {
        self.model = model
        super.init()
    }

    // MARK: - Lifecycle

    /// Requests camera access, configures the session, and starts running.
    func start(framesDirectory: URL) {
        writer = TrueDepthFrameWriter(directory: framesDirectory)
        // Drive face-down detection independently of the camera pipeline, so the
        // HUD always reflects orientation even if depth is slow to start.
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(to: motionQueue) { [model] dm, _ in
                guard let dm else { return }
                let faceDown = dm.gravity.z > Self.autoStartGravityZ
                Task { @MainActor in model.isFaceDown = faceDown }
            }
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self, model] granted in
            Task { @MainActor [model] in model.isAuthorized = granted }
            guard granted, let self else { return }
            self.sessionQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
        motion.stopDeviceMotionUpdates()
    }

    private func configureAndRun() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)

        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        depthOutput.isFilteringEnabled = true

        // Choose a video format that supports depth, preferring Float32 but
        // accepting any depth format (we convert to Float32 per frame).
        if let format = device.formats.first(where: { !$0.supportedDepthDataFormats.isEmpty }) {
            let depthFormats = format.supportedDepthDataFormats
            let depthFormat = depthFormats.first {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
            } ?? depthFormats.first
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                if let depthFormat { device.activeDepthDataFormat = depthFormat }
                device.unlockForConfiguration()
            }
        }

        session.commitConfiguration()

        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer?.setDelegate(self, queue: dataQueue)

        session.startRunning()
    }

    // MARK: - Synchronized output

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let rgb = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer)
        else { return }

        // Depth is optional — capture still saves RGB frames if it's unavailable.
        var depthData: AVDepthData?
        var depthMap: CVPixelBuffer?
        var intrinsics: simd_float3x3?
        var reference = CGSize.zero
        if let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepth.depthDataWasDropped {
            let dd = syncedDepth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            depthData = dd
            depthMap = dd.depthDataMap
            if let cal = dd.cameraCalibrationData {
                intrinsics = cal.intrinsicMatrix
                reference = cal.intrinsicMatrixReferenceDimensions
            }
        }

        let distance = depthMap.flatMap { Self.centreDistance($0) }
        let gravity = motion.deviceMotion?.gravity ?? CMAcceleration(x: 0, y: 0, z: 0)
        let attitude = motion.deviceMotion?.attitude.quaternion ?? CMQuaternion(x: 0, y: 0, z: 0, w: 1)
        let faceDown = gravity.z > Self.autoStartGravityZ
        let now = CACurrentMediaTime()

        // Auto-start (roughly face-down + in a generous range) or a manual request.
        let inRange = distance.map { $0 >= Self.autoStartNear && $0 <= Self.autoStartFar } ?? false
        if !scanning, (faceDown && inRange) || manualStartRequested { scanning = true }

        if scanning, now - lastSave >= 0.33 {
            lastSave = now
            if let depthData, let intrinsics {
                writer?.write(rgb: rgb, depthData: depthData, intrinsics: intrinsics,
                              referenceDimensions: reference,
                              attitude: attitude, gravity: gravity, timestamp: now)
            } else {
                writer?.writeRGBOnly(rgb: rgb, attitude: attitude, gravity: gravity, timestamp: now)
            }
        }

        // Live point cloud (only when depth is available).
        if let depthMap, let intrinsics, now - lastCloud >= 1.0 / 12 {
            lastCloud = now
            let cloud = DepthPointCloud.make(depthMap: depthMap, intrinsics: intrinsics, referenceDimensions: reference)
            Task { @MainActor [renderer] in renderer?.render(cloud) }
        }

        let savedCount = writer?.savedCount ?? 0
        let isScanning = scanning
        Task { @MainActor [model] in
            model.apply(distance: distance, scanning: isScanning, savedFrames: savedCount)
        }
    }

    private static func centreDistance(_ depthMap: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap), h = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let cx = w / 2, cy = h / 2, radius = 4
        var sum = 0.0, count = 0
        for dy in -radius...radius {
            let y = cy + dy; guard y >= 0, y < h else { continue }
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for dx in -radius...radius {
                let x = cx + dx; guard x >= 0, x < w else { continue }
                let d = row[x]; if d.isFinite, d > 0 { sum += Double(d); count += 1 }
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
