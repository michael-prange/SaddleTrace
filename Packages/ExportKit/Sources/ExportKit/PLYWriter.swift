import Foundation
import MeshKit

/// Writes a mesh as ASCII PLY (Design §11 mesh/point-cloud fallback).
public enum PLYWriter {

    public static func ply(from mesh: TriangleMesh) -> String {
        var out = "ply\n"
        out += "format ascii 1.0\n"
        out += "comment MeshKit export\n"
        out += "element vertex \(mesh.vertexCount)\n"
        out += "property float x\nproperty float y\nproperty float z\n"
        out += "element face \(mesh.triangleCount)\n"
        out += "property list uchar int vertex_indices\n"
        out += "end_header\n"
        for p in mesh.positions {
            out += "\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n"
        }
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            out += "3 \(a) \(b) \(c)\n"
        }
        return out
    }

    public static func write(_ mesh: TriangleMesh, to url: URL) throws {
        try ply(from: mesh).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func fmt(_ value: Float) -> String { String(format: "%.6f", value) }
}
