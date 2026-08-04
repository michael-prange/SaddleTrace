import SwiftUI
import SceneKit

/// Interactive 3D viewer for a scan's model (USDZ): rotate (drag), zoom (pinch),
/// and pan (two-finger). Shows the photo-textured reconstruction when available.
struct Model3DView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SceneKitModelView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("3D Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct SceneKitModelView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemBackground

        // Loaded meshes (esp. the fused LiDAR OBJ) can sit far from the origin in
        // ARKit world space. Flatten, recenter on the origin, and add an explicit
        // camera framed to the model so it's always visible and orbits cleanly.
        let loaded = (try? SCNScene(url: url)) ?? SCNScene()
        let model = loaded.rootNode.flattenedClone()
        let (mn, mx) = model.boundingBox
        let center = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        model.position = SCNVector3(-center.x, -center.y, -center.z)

        let scene = SCNScene()
        scene.rootNode.addChildNode(model)

        let radius = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z)) / 2
        let dist = max(radius, 0.05) * 3
        let camera = SCNCamera()
        // Orthographic: true proportions, no perspective vertical exaggeration.
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(max(radius, 0.05))
        camera.zNear = 0.001
        camera.zFar = Double(dist) * 10
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, dist)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        // Orbit around the model's center (now at the origin), not some default point.
        view.defaultCameraController.target = SCNVector3Zero
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
