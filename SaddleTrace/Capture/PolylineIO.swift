import Foundation
import simd

/// Minimal binary reader/writer for a set of 3D polylines:
///   UInt32 lineCount, then per line { UInt32 pointCount, pointCount × 3 Float32 }.
/// Used to persist the spine + cross-section tracings (capture/world frame) for
/// overlay on the painted 3D model.
nonisolated enum PolylineIO {

    static func write(_ lines: [[SIMD3<Float>]], to url: URL) throws {
        var data = Data()
        var lineCount = UInt32(lines.count)
        withUnsafeBytes(of: &lineCount) { data.append(contentsOf: $0) }
        for line in lines {
            var count = UInt32(line.count)
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            var floats = [Float](); floats.reserveCapacity(line.count * 3)
            for p in line { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
            floats.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> [[SIMD3<Float>]] {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else { return [] }
        var offset = 0
        func readU32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return v
        }
        guard let lineCount = readU32() else { return [] }
        var lines: [[SIMD3<Float>]] = []
        for _ in 0..<Int(lineCount) {
            guard let count = readU32() else { break }
            let n = Int(count)
            let bytes = n * 3 * MemoryLayout<Float>.size
            guard offset + bytes <= data.count else { break }
            var floats = [Float](repeating: 0, count: n * 3)
            _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<(offset + bytes)) }
            offset += bytes
            var line: [SIMD3<Float>] = []; line.reserveCapacity(n)
            for i in 0..<n { line.append(SIMD3<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2])) }
            lines.append(line)
        }
        return lines
    }
}
