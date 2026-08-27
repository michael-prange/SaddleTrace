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
            // drawn as green lines that always render on top of the surface.
            if let tracingsURL, let lines = try? PolylineIO.read(tracingsURL),
               let traceGeometry = Self.lineGeometry(lines, center: center) {
                scene.rootNode.addChildNode(SCNNode(geometry: traceGeometry))
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

    /// Builds a single green line geometry from polylines, recentered by `center`.
    private static func lineGeometry(_ lines: [[SIMD3<Float>]], center: SIMD3<Float>) -> SCNGeometry? {
        var verts: [SCNVector3] = []
        var idx: [UInt32] = []
        for line in lines where line.count >= 2 {
            let base = UInt32(verts.count)
            for p in line { let q = p - center; verts.append(SCNVector3(q.x, q.y, q.z)) }
            for k in 0..<(line.count - 1) { idx.append(base + UInt32(k)); idx.append(base + UInt32(k + 1)) }
        }
        guard !idx.isEmpty else { return nil }
        let source = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: idx, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.1, green: 1.0, blue: 0.2, alpha: 1)
        material.emission.contents = UIColor(red: 0.1, green: 1.0, blue: 0.2, alpha: 1)
        material.readsFromDepthBuffer = false   // always draw over the surface
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
