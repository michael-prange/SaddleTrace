import Foundation
import ModelIO
import MeshKit

/// Writes a mesh as USDZ (Design §11 default share format — Quick Look on iOS,
/// AirDrops cleanly to a Mac). Builds a `MDLMesh` from the raw buffers and
/// exports via Model I/O.
public enum USDZWriter {

    public enum ExportError: Error, Equatable {
        case unsupportedFormat
        case emptyMesh
    }

    public static func write(_ mesh: TriangleMesh, to url: URL) throws {
        guard mesh.vertexCount > 0, mesh.triangleCount > 0 else { throw ExportError.emptyMesh }
        guard MDLAsset.canExportFileExtension(url.pathExtension) else { throw ExportError.unsupportedFormat }

        let allocator = MDLMeshBufferDataAllocator()

        // Positions: SIMD3<Float> has a 16-byte stride; describe that explicitly.
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vertexData = mesh.positions.withUnsafeBytes { Data($0) }
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        let indexData = mesh.indices.withUnsafeBytes { Data($0) }
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer, indexCount: mesh.indices.count,
            indexType: .uInt32, geometryType: .triangles, material: nil
        )

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: stride)

        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer, vertexCount: mesh.vertexCount,
            descriptor: descriptor, submeshes: [submesh]
        )
        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

        let asset = MDLAsset()
        asset.add(mdlMesh)
        try asset.export(to: url)
    }
}
