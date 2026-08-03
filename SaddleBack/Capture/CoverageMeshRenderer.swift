import Foundation
import RealityKit
import UIKit

/// Renders the live scene mesh with bold, daylight-visible coverage colors
/// (Design §6.5): each face is drawn red (uncovered) / yellow (partial) /
/// green (covered) via per-face material indices. Main-actor (RealityKit).
@MainActor
final class CoverageMeshRenderer {
    private let root: AnchorEntity
    private var entities: [UUID: ModelEntity] = [:]
    private let materials: [UnlitMaterial]

    init(root: AnchorEntity) {
        self.root = root
        func material(_ color: UIColor) -> UnlitMaterial {
            UnlitMaterial(color: color.withAlphaComponent(0.72))
        }
        materials = [material(.systemRed), material(.systemYellow), material(.systemGreen)]
    }

    /// Rebuilds/updates the entity for a mesh anchor from precomputed data.
    func apply(_ data: CoverageMeshData) {
        guard data.indices.count >= 3 else { return }

        var descriptor = MeshDescriptor(name: data.id.uuidString)
        descriptor.positions = MeshBuffers.Positions(data.positions)
        descriptor.primitives = .triangles(data.indices)
        descriptor.materials = .perFace(data.perFaceMaterial)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }

        if let existing = entities[data.id] {
            existing.model = ModelComponent(mesh: mesh, materials: materials)
            existing.transform = Transform(matrix: data.transform)
        } else {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            entity.transform = Transform(matrix: data.transform)
            entities[data.id] = entity
            root.addChild(entity)
        }
    }

    func remove(_ id: UUID) {
        entities[id]?.removeFromParent()
        entities[id] = nil
    }
}
