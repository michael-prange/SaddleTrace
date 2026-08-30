import SwiftUI
import SceneKit

/// Something that can display a live depth point cloud (implemented by the
/// SceneKit view's coordinator; called on the main actor).
@MainActor
protocol PointCloudRendering: AnyObject {
    func render(_ cloud: DepthPointCloud)
}

/// A SceneKit view that renders the live depth point cloud pushed by the capture
/// controller. Rebuilds its geometry per update (throttled upstream).
struct PointCloudSceneView: UIViewRepresentable {
    let controller: TrueDepthCaptureController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .none

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.02
        cameraNode.camera?.zFar = 5
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(context.coordinator.pointsNode)
        controller.renderer = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: PointCloudRendering {
        let pointsNode = SCNNode()

        func render(_ cloud: DepthPointCloud) {
            guard !cloud.points.isEmpty else { pointsNode.geometry = nil; return }

            let vertices = cloud.points.map { SCNVector3($0.x, $0.y, $0.z) }
            let vertexSource = SCNGeometrySource(vertices: vertices)

            var colorData = Data(capacity: cloud.colors.count * MemoryLayout<SIMD3<Float>>.stride)
            for var c in cloud.colors {
                withUnsafeBytes(of: &c) { colorData.append(contentsOf: $0) }
            }
            let colorSource = SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: cloud.colors.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride)

            let indices = (0..<UInt32(cloud.points.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 6
            element.minimumPointScreenSpaceRadius = 3
            element.maximumPointScreenSpaceRadius = 8

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.isDoubleSided = true
            pointsNode.geometry = geometry
        }
    }
}
