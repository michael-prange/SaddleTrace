import SwiftUI
import SceneKit
import simd

/// Interactive viewer for a scan's captured LiDAR point cloud (coverage-colored:
/// red → yellow → green). Diagnostic: shows the raw capture and which parts the
/// mesh crop keeps (green). Rotate (drag), zoom (pinch), pan (two fingers).
struct PointCloud3DView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PointCloudSCNView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Point Cloud")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct PointCloudSCNView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.backgroundColor = .black

        let (points, colors) = (try? PointCloudIO.read(url)) ?? ([], [])
        let scene = SCNScene()

        if !points.isEmpty {
            // Recenter on the centroid so it sits at the origin and frames cleanly.
            var sum = SIMD3<Float>.zero
            for p in points { sum += p }
            let center = sum / Float(points.count)
            let centered = points.map { $0 - center }

            if let geometry = SceneKitPointCloud.geometry(points: centered, colors: colors, pointSize: 12) {
                scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            }

            var lo = centered[0], hi = centered[0]
            for p in centered { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let radius = simd_length(hi - lo) / 2
            let dist = max(radius, 0.05) * 2.2
            let camera = SCNCamera()
            camera.zNear = 0.001
            camera.zFar = Double(dist) * 10
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, dist)
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
        }

        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
