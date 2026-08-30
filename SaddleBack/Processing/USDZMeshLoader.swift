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
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { throw LoadError.noMesh }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Photogrammetry output is not always a single mesh; take every one of
        // them, offsetting each mesh's indices past the vertices already read.
        for mesh in meshes {
            guard let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition,
                                                              as: .float3) else { continue }
            let offset = UInt32(positions.count)
            let vertexCount = mesh.vertexCount
            let stride = positionData.stride
            let base = positionData.dataStart
            positions.reserveCapacity(positions.count + vertexCount)
            for i in 0..<vertexCount {
                let p = base.advanced(by: i * stride).assumingMemoryBound(to: (Float, Float, Float).self).pointee
                positions.append(SIMD3<Float>(p.0, p.1, p.2))
            }

            for case let submesh as MDLSubmesh in (mesh.submeshes ?? []) {
                guard submesh.geometryType == .triangles else { continue }
                let map = submesh.indexBuffer.map()
                let ptr = map.bytes
                let count = submesh.indexCount
                // A partial triangle would desync every face after it; drop the remainder.
                let usable = count - count % 3
                var read: [UInt32] = []
                read.reserveCapacity(usable)
                switch submesh.indexType {
                case .uInt32:
                    for i in 0..<usable { read.append(ptr.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee) }
                case .uInt16:
                    for i in 0..<usable { read.append(UInt32(ptr.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)) }
                case .uInt8:
                    for i in 0..<usable { read.append(UInt32(ptr.advanced(by: i).assumingMemoryBound(to: UInt8.self).pointee)) }
                default:
                    continue
                }
                // Skip faces that point outside this mesh's own vertices rather than
                // letting them index into the previous mesh's geometry.
                var t = 0
                while t + 2 < read.count {
                    let a = read[t], b = read[t + 1], c = read[t + 2]
                    if Int(a) < vertexCount, Int(b) < vertexCount, Int(c) < vertexCount {
                        indices.append(contentsOf: [a + offset, b + offset, c + offset])
                    }
                    t += 3
                }
            }
        }

        // TriangleMesh's initializer traps on a bad index count; report it instead.
        guard !positions.isEmpty, indices.count.isMultiple(of: 3) else { throw LoadError.noMesh }
        return TriangleMesh(positions: positions, indices: indices)
    }
}
