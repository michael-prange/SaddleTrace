import Foundation
import MeshKit

/// Writes a mesh as Wavefront OBJ (Design §11, for Blender/MeshLab/CAD import).
/// Delegates to `MeshKit.MeshIO` so OBJ round-trips through a single code path.
public enum OBJWriter {

    public static func obj(from mesh: TriangleMesh) -> String {
        MeshIO.objString(from: mesh)
    }

    public static func write(_ mesh: TriangleMesh, to url: URL) throws {
        try MeshIO.writeOBJ(mesh, to: url)
    }
}
