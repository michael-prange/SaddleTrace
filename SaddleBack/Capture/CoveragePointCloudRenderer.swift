import Foundation
import SceneKit

/// Renders the LiDAR scene mesh as **see-through colored dots** (Design §6.5,
/// revised per field feedback): one point per mesh vertex, red/yellow/green by
/// coverage, over the AR camera feed. Main-actor (SceneKit).
@MainActor
final class CoveragePointCloudRenderer {
    private let root: SCNNode
    private var nodes: [UUID: SCNNode] = [:]

    init(root: SCNNode) { self.root = root }

    func apply(_ data: CoveragePointData) {
        let geometry = SceneKitPointCloud.geometry(points: data.points, colors: data.colors, pointSize: 14)
        if let node = nodes[data.id] {
            node.geometry = geometry
        } else {
            let node = SCNNode()
            node.geometry = geometry
            nodes[data.id] = node
            root.addChildNode(node)
        }
    }

    func remove(_ id: UUID) {
        nodes[id]?.removeFromParentNode()
        nodes[id] = nil
    }
}
