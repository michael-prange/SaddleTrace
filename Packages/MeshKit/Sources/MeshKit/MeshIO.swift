import Foundation
import simd

/// Minimal Wavefront OBJ reader/writer for triangle meshes. Handles `v` and `f`
/// records; face records may carry `v`, `v/vt`, `v/vt/vn`, or `v//vn` forms and
/// are triangulated by fan if a polygon has more than three corners. Texture and
/// normal data are ignored — MeshKit only needs geometry.
public enum MeshIO {

    public enum OBJError: Error, Equatable {
        case malformedVertex(line: Int)
        case malformedFace(line: Int)
        case faceIndexOutOfRange(line: Int)
    }

    /// Serializes a mesh to OBJ text. Indices are emitted 1-based per the format.
    public static func objString(from mesh: TriangleMesh) -> String {
        var out = "# MeshKit OBJ export\n"
        out.reserveCapacity(mesh.positions.count * 24 + mesh.indices.count * 8)
        for p in mesh.positions {
            out += "v \(p.x) \(p.y) \(p.z)\n"
        }
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[3 * t] + 1
            let b = mesh.indices[3 * t + 1] + 1
            let c = mesh.indices[3 * t + 2] + 1
            out += "f \(a) \(b) \(c)\n"
        }
        return out
    }

    /// Parses OBJ text into a `TriangleMesh`.
    public static func mesh(fromOBJ text: String) throws -> TriangleMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for (lineNo, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = fields.first else { continue }

            switch tag {
            case "v":
                guard fields.count >= 4,
                      let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3])
                else { throw OBJError.malformedVertex(line: lineNo + 1) }
                positions.append(SIMD3<Float>(x, y, z))

            case "f":
                let corners = fields.dropFirst()
                guard corners.count >= 3 else { throw OBJError.malformedFace(line: lineNo + 1) }
                var faceIndices: [UInt32] = []
                faceIndices.reserveCapacity(corners.count)
                for corner in corners {
                    // Take the vertex index before any '/'; OBJ is 1-based and
                    // permits negative (relative) indices.
                    let token = corner.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    guard let raw = Int(token) else { throw OBJError.malformedFace(line: lineNo + 1) }
                    let resolved = raw > 0 ? raw - 1 : positions.count + raw
                    guard resolved >= 0 && resolved < positions.count else {
                        throw OBJError.faceIndexOutOfRange(line: lineNo + 1)
                    }
                    faceIndices.append(UInt32(resolved))
                }
                // Fan-triangulate polygons with more than three corners.
                for k in 1..<(faceIndices.count - 1) {
                    indices.append(contentsOf: [faceIndices[0], faceIndices[k], faceIndices[k + 1]])
                }

            default:
                continue
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Reads an OBJ file from disk.
    public static func readOBJ(at url: URL) throws -> TriangleMesh {
        try mesh(fromOBJ: String(contentsOf: url, encoding: .utf8))
    }

    /// Writes a mesh to disk as OBJ.
    public static func writeOBJ(_ mesh: TriangleMesh, to url: URL) throws {
        try objString(from: mesh).write(to: url, atomically: true, encoding: .utf8)
    }
}
