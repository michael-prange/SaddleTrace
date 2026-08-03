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
        view.scene = (try? SCNScene(url: url)) ?? SCNScene()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
