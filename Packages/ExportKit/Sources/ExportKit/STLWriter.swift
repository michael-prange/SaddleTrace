import Foundation
import simd
import MeshKit

/// Writes a mesh as **binary STL** (Design §11, saddle-CAD / 3D-print interchange).
/// STL is unitless; consumers conventionally assume millimetres, so metres are
/// scaled to mm by default.
public enum STLWriter {

    /// Metres → millimetres (STL's conventional unit).
    public static func binarySTL(from mesh: TriangleMesh, scale: Float = 1000) -> Data {
        var data = Data(capacity: 84 + mesh.triangleCount * 50)
        data.append(Data(count: 80))                       // header
        appendUInt32(UInt32(mesh.triangleCount), to: &data)

        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            var normal = simd_cross(b - a, c - a)
            let len = simd_length(normal)
            normal = len > 0 ? normal / len : SIMD3<Float>(0, 0, 0)
            append(normal, to: &data)
            append(a * scale, to: &data)
            append(b * scale, to: &data)
            append(c * scale, to: &data)
            appendUInt16(0, to: &data)                     // attribute byte count
        }
        return data
    }

    public static func write(_ mesh: TriangleMesh, to url: URL, scale: Float = 1000) throws {
        try binarySTL(from: mesh, scale: scale).write(to: url, options: .atomic)
    }

    private static func append(_ v: SIMD3<Float>, to data: inout Data) {
        for var f in [v.x, v.y, v.z] { withUnsafeBytes(of: &f) { data.append(contentsOf: $0) } }
    }
    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var v = value; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var v = value; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
