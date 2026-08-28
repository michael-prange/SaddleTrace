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

        let scene = SCNScene()
        let (positions, colors, indices) = (try? PaintedMeshIO.read(url)) ?? ([], [], [])

        if positions.count >= 3, indices.count >= 3 {
            // Recenter on the bounding-box center so it frames + orbits cleanly.
            var lo = positions[0], hi = positions[0]
            for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let center = (lo + hi) / 2
            let centered = positions.map { $0 - center }

            let vertexSource = SCNGeometrySource(vertices: centered.map { SCNVector3($0.x, $0.y, $0.z) })
            var colorData = Data(capacity: colors.count * MemoryLayout<SIMD3<Float>>.stride)
            for var c in colors { withUnsafeBytes(of: &c) { colorData.append(contentsOf: $0) } }
            let colorSource = SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            // Unlit: the photo already carries shading, so show its colors directly.
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.isDoubleSided = true
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))

            // Spine + section tracings (same world frame), recentered identically and
            // drawn as bold tubes that always render on top of the surface.
            for node in TracingTubes.nodes(tracingsURL: tracingsURL, center: center,
                                           modelExtent: simd_length(hi - lo)) {
                scene.rootNode.addChildNode(node)
            }

            let radius = simd_length(hi - lo) / 2
            let dist = max(radius, 0.05) * 3
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(max(radius, 0.05))
            camera.zNear = 0.001
            camera.zFar = Double(dist) * 10
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, dist)
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
            view.defaultCameraController.target = SCNVector3Zero
        }

        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
