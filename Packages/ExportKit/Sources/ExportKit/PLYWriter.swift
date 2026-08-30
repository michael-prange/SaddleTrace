import Foundation
import simd
import MeshKit

/// Writes a mesh as ASCII PLY (Design §11 mesh/point-cloud fallback).
public enum PLYWriter {

    /// Writes a per-vertex-colored PLY (positions + RGB + triangle faces). Colors
    /// are 0–1 floats, emitted as `uchar` 0–255. Used for the photo-painted surface.
    public static func coloredPLY(positions: [SIMD3<Float>], colors: [SIMD3<Float>],
                                  indices: [UInt32]) -> String {
        let n = min(positions.count, colors.count)
        // Only faces whose three corners survive the vertex count are emitted —
        // otherwise a colors/positions mismatch would produce out-of-range face
        // indices and an unreadable file.
        var faces: [(UInt32, UInt32, UInt32)] = []
        var f = 0
        while f + 2 < indices.count {
            let a = indices[f], b = indices[f + 1], c = indices[f + 2]
            if Int(a) < n, Int(b) < n, Int(c) < n { faces.append((a, b, c)) }
            f += 3
        }

        var out = "ply\nformat ascii 1.0\ncomment SaddleBack painted surface\n"
        out += "element vertex \(n)\n"
        out += "property float x\nproperty float y\nproperty float z\n"
        out += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        out += "element face \(faces.count)\n"
        out += "property list uchar int vertex_indices\n"
        out += "end_header\n"
        func byte(_ v: Float) -> Int { min(max(Int(v * 255), 0), 255) }
        for i in 0..<n {
            let p = positions[i], c = colors[i]
            out += "\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z)) \(byte(c.x)) \(byte(c.y)) \(byte(c.z))\n"
        }
        for (a, b, c) in faces {
            out += "3 \(a) \(b) \(c)\n"
        }
        return out
    }

    public static func writeColored(positions: [SIMD3<Float>], colors: [SIMD3<Float>],
                                    indices: [UInt32], to url: URL) throws {
        try coloredPLY(positions: positions, colors: colors, indices: indices)
            .write(to: url, atomically: true, encoding: .utf8)
    }

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
