import SwiftUI
import ARKit
import SceneKit
import MeshKit

/// Observable state for the single-shot LiDAR capture screen.
@MainActor
@Observable
final class LiDARShotModel {
    var distanceMeters: Double?
    var state: CaptureDistanceState = .noSurface
    /// A shot has been captured and saved.
    var shotCaptured = false
    /// A capture/save is in progress.
    var isBusy = false
    var errorText: String?

    /// The just-captured cloud, shown immediately for review before saving is done.
    var capturedPoints: [SIMD3<Float>] = []
    var capturedColors: [SIMD3<Float>] = []

    /// Set by the preview: reads the current frame, builds the mesh + cloud, saves.
    var capture: (() -> Void)?

    // Comfortable holding band for a ~20 in footprint (m); ~0.6 m frames ~20 in.
    let nearLimit = 0.50
    let farLimit = 0.70

    func classify(_ d: Double?) -> CaptureDistanceState {
        guard let d else { return .noSurface }
        if d < nearLimit { return .tooClose }
        if d > farLimit { return .tooFar }
        return .justRight
    }
}

/// Full-screen single **LiDAR shot** capture (Design §6, revised): hold the phone
/// above the saddle area (angling forward is fine), frame the back in the box, and
/// tap once. One instant depth frame becomes a dense surface — no sweeping.
struct LiDARShotCaptureView: View {
    let animal: AnimalRecord
    let onFinish: (URL?) -> Void
    let onCancel: (URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = LiDARShotModel()
    @State private var framesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lidarshot_\(UUID().uuidString)", isDirectory: true)

    var body: some View {
        ZStack {
            if !CaptureCapabilities.hasLiDAR {
                unsupported
            } else if model.shotCaptured {
                reviewView
            } else {
                liveCaptureView
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                cleanupTemp()
                onCancel(nil)
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.headline).padding(10)
                    .background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white)
            }
            .padding()
        }
        .statusBarHidden()
    }

    // MARK: Live capture

    private var liveCaptureView: some View {
        ZStack {
            ARDepthPreview(model: model, framesDirectory: framesDirectory)
                .ignoresSafeArea()

            framingOverlay

            HStack {
                Spacer()
                DistanceHUD(state: model.state, distanceMeters: model.distanceMeters,
                            nearLimit: model.nearLimit, farLimit: model.farLimit)
            }
            .padding()

            VStack {
                banner
                Spacer()
                shutter
            }
        }
    }

    // MARK: Review (instant 3D point cloud)

    private var reviewView: some View {
        ZStack {
            StaticPointCloudView(points: model.capturedPoints, colors: model.capturedColors)
                .ignoresSafeArea()
                .background(.black)

            VStack {
                Text("Rotate to inspect — retake if the back isn't fully captured")
                    .font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 8)
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        cleanupTemp()
                        model.capturedPoints = []; model.capturedColors = []
                        model.shotCaptured = false
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    // Retaking mid-save deleted the directory the background write
                    // was still writing into, and its completion then flipped
                    // `shotCaptured` back on over an emptied point cloud.
                    .disabled(model.isBusy)

                    Button {
                        onFinish(framesDirectory)
                        dismiss()
                    } label: {
                        HStack {
                            if model.isBusy { ProgressView().tint(.white) }
                            Text(model.isBusy ? "Saving…" : "Use This Shot")
                        }
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
                .padding()
            }
        }
    }

    // MARK: Overlay

    private var framingOverlay: some View {
        GeometryReader { geo in
            // Guide box for the saddle region: ~20 in long × 16 in wide → 4:5.
            let boxH = geo.size.height * 0.7
            let boxW = boxH * 0.8
            RoundedRectangle(cornerRadius: 16)
                .stroke(model.shotCaptured ? Color.green : Color.white.opacity(0.9),
                        style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .frame(width: boxW, height: boxH)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private var banner: some View {
        Text(bannerText)
            .font(.callout).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.top, 8)
    }

    private var bannerText: String {
        if let e = model.errorText { return e }
        if model.shotCaptured { return "Captured ✓ — use it or retake" }
        switch model.state {
        case .tooClose: return "A little farther — fill the box with the saddle area"
        case .tooFar: return "A little closer — about 20 in of back"
        case .justRight: return "Good distance — center the spine, then tap Capture"
        case .noSurface: return "Aim at the back; angle forward to see the spine"
        }
    }

    // MARK: Controls

    private var shutter: some View {
        Button {
            model.capture?()
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 60, height: 60)
                if model.isBusy { ProgressView() }
            }
        }
        .disabled(model.isBusy)
        .padding(.bottom, 28)
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("LiDAR Required", systemImage: "camera.metering.unknown")
        } description: {
            Text("Single-shot capture needs a Pro iPhone with a LiDAR scanner.")
        } actions: {
            Button("Close") { onCancel(nil); dismiss() }
        }
    }

    private func cleanupTemp() {
        try? FileManager.default.removeItem(at: framesDirectory)
    }
}

/// ARSCNView camera preview with scene depth. Updates the distance readout and,
/// on request, captures one frame into a dense mesh + point cloud.
private struct ARDepthPreview: UIViewRepresentable {
    let model: LiDARShotModel
    let framesDirectory: URL

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.worldAlignment = .gravity
        config.planeDetection = []
        view.session.run(config)

        // Capture closure: build the mesh on the main actor (reads AR buffers),
        // then write to disk off-main to keep the shutter responsive.
        // `model` is captured WEAKLY: the model owns this closure, so a strong
        // capture here is a reference cycle that leaks the model and its point
        // clouds for every capture session.
        model.capture = { [weak model, weak view] in
            guard let model else { return }
            guard let frame = view?.session.currentFrame else {
                model.errorText = "No camera frame yet — hold steady"; return
            }
            guard let result = DepthGridMesh.build(from: frame) else {
                model.errorText = "No depth captured — move a little and retry"; return
            }
            // Show the cloud immediately for review; saving finishes in the background.
            model.capturedPoints = result.points
            model.capturedColors = result.colors
            model.shotCaptured = true
            model.isBusy = true
            model.errorText = nil
            // Raw capture inputs (photo + depth + confidence + calibration), extracted
            // while the frame is valid, so the whole build can be re-run on the archive
            // when the code improves.
            let raw = RawShotWriter.extract(from: frame)
            let dir = framesDirectory
            Task.detached {
                var ok = true
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try MeshIO.writeOBJ(result.mesh, to: dir.appendingPathComponent("lidar.obj"))
                    try PointCloudIO.write(points: result.points, colors: result.colors,
                                           to: dir.appendingPathComponent("pointcloud.bin"))
                    // Photo-painted surface for the 3D viewer.
                    try PaintedMeshIO.write(positions: result.mesh.positions, colors: result.photoColors,
                                            indices: result.mesh.indices,
                                            to: dir.appendingPathComponent("surface.bin"))
                } catch { ok = false }
                RawShotWriter.persist(raw, to: dir)
                await MainActor.run {
                    model.isBusy = false
                    model.shotCaptured = ok
                    if !ok { model.errorText = "Couldn't save the shot" }
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    nonisolated final class Coordinator: NSObject, ARSessionDelegate {
        private let model: LiDARShotModel
        private var lastUpdate = CFAbsoluteTimeGetCurrent()

        init(model: LiDARShotModel) { self.model = model }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastUpdate >= 0.1 else { return }
            lastUpdate = now
            let distance = Self.centreDistance(of: frame)
            Task { @MainActor [model] in
                model.distanceMeters = distance
                if !model.shotCaptured { model.state = model.classify(distance) }
            }
        }

        private static func centreDistance(of frame: ARFrame) -> Double? {
            guard let depth = frame.sceneDepth?.depthMap else { return nil }
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
            let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
            let rowBytes = CVPixelBufferGetBytesPerRow(depth)
            guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
            let cx = w / 2, cy = h / 2, radius = 3
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
}
