import Foundation
import ModelIO
import simd
import MeshKit

/// Loads a USDZ (e.g. a `PhotogrammetrySession` result) into a `MeshKit`
/// `TriangleMesh`. The USD is Y-up; callers swap to MeshKit's Z-up frame.
nonisolated enum USDZMeshLoader {

    enum LoadError: Error, Equatable { case noMesh }

    static func loadTriangleMesh(from url: URL) throws -> TriangleMesh {
        let asset = MDLAsset(url: url)
        guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else {
            throw LoadError.noMesh
        }

        // Positions.
        guard let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            throw LoadError.noMesh
        }
        let vertexCount = mesh.vertexCount
        let stride = positionData.stride
        let base = positionData.dataStart
        var positions = [SIMD3<Float>](); positions.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let p = base.advanced(by: i * stride).assumingMemoryBound(to: (Float, Float, Float).self).pointee
            positions.append(SIMD3<Float>(p.0, p.1, p.2))
        }

        // Triangle indices from all submeshes.
        var indices = [UInt32]()
        for case let submesh as MDLSubmesh in (mesh.submeshes ?? []) {
            guard submesh.geometryType == .triangles else { continue }
            let map = submesh.indexBuffer.map()
            let ptr = map.bytes
            let count = submesh.indexCount
            switch submesh.indexType {
            case .uInt32:
                for i in 0..<count { indices.append(ptr.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee) }
            case .uInt16:
                for i in 0..<count { indices.append(UInt32(ptr.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)) }
            case .uInt8:
                for i in 0..<count { indices.append(UInt32(ptr.advanced(by: i).assumingMemoryBound(to: UInt8.self).pointee)) }
            default:
                break
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }
}
