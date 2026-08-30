import Foundation
import simd

/// Minimal binary reader/writer for a per-vertex-colored triangle mesh:
///   UInt32 vertexCount, then vertexCount × 6 Float32 (x,y,z,r,g,b),
///   UInt32 indexCount,  then indexCount  × UInt32.
/// Used to persist the photo-painted single-shot surface for the 3D viewer.
nonisolated enum PaintedMeshIO {

    static func write(positions: [SIMD3<Float>], colors: [SIMD3<Float>],
                      indices: [UInt32], to url: URL) throws {
        let n = min(positions.count, colors.count)
        var floats = [Float](); floats.reserveCapacity(n * 6)
        for i in 0..<n {
            let p = positions[i], c = colors[i]
            floats.append(p.x); floats.append(p.y); floats.append(p.z)
            floats.append(c.x); floats.append(c.y); floats.append(c.z)
        }
        var data = Data()
        var vCount = UInt32(n)
        withUnsafeBytes(of: &vCount) { data.append(contentsOf: $0) }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        var iCount = UInt32(indices.count)
        withUnsafeBytes(of: &iCount) { data.append(contentsOf: $0) }
        indices.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> (positions: [SIMD3<Float>], colors: [SIMD3<Float>], indices: [UInt32]) {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { return ([], [], []) }
        let vCount = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let floatBytes = vCount * 6 * MemoryLayout<Float>.size
        guard data.count >= 4 + floatBytes + 4 else { return ([], [], []) }

        var floats = [Float](repeating: 0, count: vCount * 6)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 4..<(4 + floatBytes)) }

        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(vCount)
        var colors: [SIMD3<Float>] = []; colors.reserveCapacity(vCount)
        for i in 0..<vCount {
            let b = i * 6
            positions.append(SIMD3<Float>(floats[b], floats[b + 1], floats[b + 2]))
            colors.append(SIMD3<Float>(floats[b + 3], floats[b + 4], floats[b + 5]))
        }

        let iOffset = 4 + floatBytes
        let iCount = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: iOffset, as: UInt32.self) })
        let idxBytes = iCount * MemoryLayout<UInt32>.size
        guard data.count >= iOffset + 4 + idxBytes else { return (positions, colors, []) }
        var indices = [UInt32](repeating: 0, count: iCount)
        _ = indices.withUnsafeMutableBytes { data.copyBytes(to: $0, from: (iOffset + 4)..<(iOffset + 4 + idxBytes)) }
        return (positions, colors, indices)
    }
}
