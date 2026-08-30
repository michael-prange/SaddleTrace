import Foundation
import simd

/// Minimal binary reader/writer for a colored point cloud: a `UInt32` count
/// followed by `count × 6` little-endian `Float32` (x, y, z, r, g, b). Used to
/// persist the full captured LiDAR cloud (colored by coverage) for the diagnostic
/// point-cloud viewer. Pure Foundation + simd, so it's usable from the AR queue.
nonisolated enum PointCloudIO {

    static func write(points: [SIMD3<Float>], colors: [SIMD3<Float>], to url: URL) throws {
        let n = min(points.count, colors.count)
        var floats = [Float](); floats.reserveCapacity(n * 6)
        for i in 0..<n {
            let p = points[i], c = colors[i]
            floats.append(p.x); floats.append(p.y); floats.append(p.z)
            floats.append(c.x); floats.append(c.y); floats.append(c.z)
        }
        var data = Data()
        var count = UInt32(n)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> (points: [SIMD3<Float>], colors: [SIMD3<Float>]) {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { return ([], []) }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let floatCount = count * 6
        guard data.count >= 4 + floatCount * MemoryLayout<Float>.size else { return ([], []) }

        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, from: 4..<(4 + floatCount * MemoryLayout<Float>.size))
        }
        var points: [SIMD3<Float>] = []; points.reserveCapacity(count)
        var colors: [SIMD3<Float>] = []; colors.reserveCapacity(count)
        for i in 0..<count {
            let b = i * 6
            points.append(SIMD3<Float>(floats[b], floats[b + 1], floats[b + 2]))
            colors.append(SIMD3<Float>(floats[b + 3], floats[b + 4], floats[b + 5]))
        }
        return (points, colors)
    }
}
