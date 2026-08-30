import Foundation
import SceneKit
import simd

/// Builds a SceneKit point-cloud geometry (colored dots) from positions + colors.
/// Shared by the front depth cloud and the LiDAR coverage cloud so both render as
/// see-through dots.
@MainActor
enum SceneKitPointCloud {
    static func geometry(points: [SIMD3<Float>], colors: [SIMD3<Float>], pointSize: CGFloat) -> SCNGeometry? {
        guard !points.isEmpty, points.count == colors.count else { return nil }

        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var colorData = Data(capacity: colors.count * MemoryLayout<SIMD3<Float>>.stride)
        for var c in colors { withUnsafeBytes(of: &c) { colorData.append(contentsOf: $0) } }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let indices = (0..<UInt32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = max(pointSize, 8)

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.isDoubleSided = true
        return geometry
    }
}
