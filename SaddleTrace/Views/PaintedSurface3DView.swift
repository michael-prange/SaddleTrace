import SwiftUI
import SceneKit
import simd
import UIKit

/// Interactive viewer for the photo-painted single-shot surface (per-vertex color
/// sampled from the capture photo), with the spine + cross-section tracings drawn
/// as green curves so the fitter sees exactly where the sections fall relative to
/// any marks on the coat. Rotate (drag), zoom (pinch), pan (two fingers).
struct PaintedSurface3DView: View {
    let url: URL
    var tracingsURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaintedSurfaceSCNView(url: url, tracingsURL: tracingsURL)
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

private struct PaintedSurfaceSCNView: UIViewRepresentable {
    let url: URL
    let tracingsURL: URL?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.backgroundColor = .black

        if let (scene, camera, _) = PaintedScene.make(surfaceURL: url, tracingsURL: tracingsURL) {
            view.scene = scene
            view.pointOfView = camera
            view.defaultCameraController.target = SCNVector3Zero
        } else {
            view.scene = SCNScene()
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
