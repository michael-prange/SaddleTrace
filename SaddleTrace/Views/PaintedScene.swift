import SceneKit
import simd

/// Builds the photo-painted surface + spine/section tracing tubes + a framed
/// orthographic camera — the exact scene shown in `PaintedSurface3DView`. Shared
/// so the interactive viewer and the PDF's offscreen snapshot render identically.
enum PaintedScene {

    /// Returns the scene, its camera node, and the model's centered half-extents
    /// (for callers that want to reframe, e.g. a tight PDF snapshot). Nil if the
    /// surface can't be read. `tubeRadiusScale` thins the tracing tubes (the PDF
    /// snapshot uses a smaller value so the curves obscure less of the back).
    static func make(surfaceURL: URL, tracingsURL: URL?, tubeRadiusScale: Float = 1)
        -> (scene: SCNScene, camera: SCNNode, halfExtent: SIMD3<Float>)? {
        guard let (positions, colors, indices) = try? PaintedMeshIO.read(surfaceURL),
              positions.count >= 3, indices.count >= 3 else { return nil }

        let scene = SCNScene()

        // Recenter on the bounding-box center so it frames cleanly.
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

        // Spine + section tracings (same world frame), recentered identically.
        for node in TracingTubes.nodes(tracingsURL: tracingsURL, center: center,
                                       modelExtent: simd_length(hi - lo), radiusScale: tubeRadiusScale) {
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

        return (scene, cameraNode, (hi - lo) / 2)
    }
}
