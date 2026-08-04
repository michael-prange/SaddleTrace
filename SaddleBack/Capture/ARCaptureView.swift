import SwiftUI
import ARKit
import SceneKit
import MeshKit

/// Hosts an `ARSCNView` running world tracking with LiDAR scene reconstruction
/// (Design §6.1). Renders the scene mesh live as **see-through coverage dots**
/// over the camera feed (§6.5), saves posed frames (§6.2), and drives the
/// distance/coverage HUD. Frames are written to `framesDirectory` (a temp folder
/// promoted into the scan on Finish).
struct ARCaptureView: UIViewRepresentable {
    let model: CaptureModel
    let framesDirectory: URL

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.scene.rootNode.addChildNode(context.coordinator.pointsRoot)
        context.coordinator.renderer = CoveragePointCloudRenderer(root: context.coordinator.pointsRoot)

        // Bridge Finish → coordinator: the coordinator writes the fused LiDAR mesh
        // on its AR queue (where the coverage tracker is safe to read).
        let coordinator = context.coordinator
        model.requestMeshExport = { url in coordinator.pendingExportURL = url }

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }
        config.frameSemantics.insert(.sceneDepth)
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        config.planeDetection = []
        view.session.run(config)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, snapshotter: FrameSnapshotter(directory: framesDirectory))
    }

    /// AR session delegate (nonisolated; runs on ARKit's serial queue). Owns the
    /// snapshotter and coverage tracker; hands Sendable point data to the
    /// main-actor renderer and model.
    nonisolated final class Coordinator: NSObject, ARSessionDelegate {
        private let model: CaptureModel
        private let snapshotter: FrameSnapshotter
        private let tracker = CoverageTracker()

        /// Root node for the coverage dots; created on the main actor with the
        /// coordinator (SwiftUI makes coordinators on main).
        let pointsRoot = SCNNode()
        // Strong reference — a weak one deallocates immediately (nothing else
        // retains it), which is why the coverage dots never appeared.
        nonisolated(unsafe) var renderer: CoveragePointCloudRenderer?

        /// Set on the main actor when the user taps Finish; consumed once on the
        /// AR queue to write the fused LiDAR mesh. One-shot signal.
        nonisolated(unsafe) var pendingExportURL: URL?
        private var exportDone = false

        private var lastFrameUpdate = CFAbsoluteTimeGetCurrent()
        private var lastMeshUpdate = CFAbsoluteTimeGetCurrent()

        init(model: CaptureModel, snapshotter: FrameSnapshotter) {
            self.model = model
            self.snapshotter = snapshotter
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Finish requested: write the fused, coverage-cropped LiDAR mesh once.
            if let url = pendingExportURL, !exportDone {
                exportDone = true
                pendingExportURL = nil
                let ok = writeFusedMesh(from: frame, to: url)
                Task { @MainActor [model] in model.meshExportFinished = ok }
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastFrameUpdate >= 0.1 else { return }
            lastFrameUpdate = now

            let distance = Self.centreDistance(of: frame)
            let trackingNormal: Bool = { if case .normal = frame.camera.trackingState { true } else { false } }()

            if let savedPosition = snapshotter.consider(frame) {
                let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                var faces: [(centroid: SIMD3<Float>, normal: SIMD3<Float>)] = []
                for anchor in meshAnchors {
                    faces.append(contentsOf: MeshAnchorGeometry.faceCentroidsAndNormals(anchor))
                }
                tracker.registerSnapshot(faces: faces, cameraPosition: savedPosition)
            }

            let savedCount = snapshotter.savedCount
            let coverage = tracker.progress.fraction
            Task { @MainActor [model] in
                model.savedFrameCount = savedCount
                model.coverageFraction = coverage
                model.update(distance: distance, trackingNormal: trackingNormal)
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastMeshUpdate >= 0.2 else { return }
            lastMeshUpdate = now

            let data = anchors.compactMap { $0 as? ARMeshAnchor }
                .compactMap { MeshAnchorGeometry.coveragePointData(for: $0, tracker: tracker) }
            guard !data.isEmpty else { return }
            Task { @MainActor [renderer] in
                for datum in data { renderer?.apply(datum) }
            }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            let ids = anchors.map(\.identifier)
            Task { @MainActor [renderer] in
                for id in ids { renderer?.remove(id) }
            }
        }

        /// Writes the fused, coverage-cropped scene mesh (ARKit world, Y-up) to
        /// `url` as OBJ, plus the full uncropped coverage-colored point cloud beside
        /// it (`pointcloud.bin`). Runs on the AR queue, where the tracker is safe to read.
        private func writeFusedMesh(from frame: ARFrame, to url: URL) -> Bool {
            let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

            // Full captured cloud (uncropped) for the diagnostic viewer — best-effort.
            let cloud = MeshAnchorGeometry.fusedPointCloud(anchors: anchors, tracker: tracker)
            if !cloud.points.isEmpty {
                let cloudURL = url.deletingLastPathComponent().appendingPathComponent("pointcloud.bin")
                try? PointCloudIO.write(points: cloud.points, colors: cloud.colors, to: cloudURL)
            }

            let (positions, indices) = MeshAnchorGeometry.fusedScannedMesh(anchors: anchors, tracker: tracker)
            guard indices.count >= 3 else { return false }
            do {
                try MeshIO.writeOBJ(TriangleMesh(positions: positions, indices: indices), to: url)
                return true
            } catch { return false }
        }

        private static func centreDistance(of frame: ARFrame) -> Double? {
            guard let depth = frame.sceneDepth?.depthMap else { return nil }
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
            let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
            let rowBytes = CVPixelBufferGetBytesPerRow(depth)
            guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
            let cx = width / 2, cy = height / 2, radius = 3
            var sum = 0.0, count = 0
            for dy in -radius...radius {
                let y = cy + dy; guard y >= 0, y < height else { continue }
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for dx in -radius...radius {
                    let x = cx + dx; guard x >= 0, x < width else { continue }
                    let d = row[x]; if d.isFinite, d > 0 { sum += Double(d); count += 1 }
                }
            }
            return count > 0 ? sum / Double(count) : nil
        }
    }
}
