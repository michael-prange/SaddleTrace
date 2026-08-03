import Foundation
import simd

/// Generates a parametric "back-like" mesh with known ground truth, per the
/// testing strategy in Design §15. The surface is a closed tube swept along +X
/// whose top ridge height follows a profile with a withers peak, a loin dip, and
/// a secondary croup peak — enough structure to exercise long-axis PCA, spine
/// fitting, landmark detection, ROI cropping, and cross-sectioning.
public enum SyntheticBackMesh {

    /// Ground-truth landmark arc positions (as X, since the raw mesh is already
    /// aligned to +X). Distances in metres from the cranial end (X = 0).
    public struct GroundTruth: Sendable, Equatable {
        public let withersX: Float
        public let loinX: Float
        public let croupX: Float
        public let tailX: Float
        /// 15 cm cranial of the withers (Design §7.3 front cutoff).
        public let frontX: Float
        public let radius: Float
    }

    /// Builds the mesh and its ground truth.
    ///
    /// - Parameters:
    ///   - length: cranio-caudal extent in metres.
    ///   - segmentsAlong: number of rings minus one along X.
    ///   - segmentsAround: vertices per ring.
    ///   - radius: tube radius in metres.
    public static func make(
        length: Float = 1.4,
        segmentsAlong: Int = 140,
        segmentsAround: Int = 48,
        radius: Float = 0.28
    ) -> (mesh: TriangleMesh, truth: GroundTruth) {
        precondition(segmentsAlong >= 1 && segmentsAround >= 3)

        let withersX = 0.28 * length
        let loinX = 0.55 * length
        let croupX = 0.78 * length
        let tailX = length
        let frontX = withersX - 0.15

        // Top-ridge height (Z) as a function of X. Global max at the withers, a
        // secondary max at the croup, a dip at the loin, all above the 0.8 m
        // floor threshold used by the long-axis filter.
        func topZ(_ x: Float) -> Float {
            let base: Float = 1.25
            func gauss(_ c: Float, _ sigma: Float) -> Float {
                let t = (x - c) / sigma
                return exp(-0.5 * t * t)
            }
            return base
                + 0.12 * gauss(withersX, 0.11)   // withers
                + 0.08 * gauss(croupX, 0.13)      // croup
                - 0.05 * gauss(loinX, 0.14)       // loin dip
        }

        let mesh = buildTube(length: length, segmentsAlong: segmentsAlong,
                             segmentsAround: segmentsAround, radius: radius, topZ: topZ)
        let truth = GroundTruth(
            withersX: withersX, loinX: loinX, croupX: croupX,
            tailX: tailX, frontX: frontX, radius: radius
        )
        return (mesh, truth)
    }

    /// A straight circular tube along +X with constant top-ridge height. Because
    /// the spine tangent is exactly +X everywhere, transverse sections are exact
    /// circles of the given `radius` centred one radius below the spine — clean
    /// ground truth for cross-section and metric tests.
    public static func straightCylinder(
        length: Float = 1.2,
        segmentsAlong: Int = 120,
        segmentsAround: Int = 64,
        radius: Float = 0.28,
        topHeight: Float = 1.48
    ) -> TriangleMesh {
        buildTube(length: length, segmentsAlong: segmentsAlong,
                  segmentsAround: segmentsAround, radius: radius) { _ in topHeight }
    }

    /// Sweeps a closed circular tube along +X, with the top-ridge height given by
    /// `topZ(x)`. The highest vertex of each ring equals `topZ(x)`; Y is lateral.
    private static func buildTube(
        length: Float, segmentsAlong: Int, segmentsAround: Int, radius: Float,
        topZ: (Float) -> Float
    ) -> TriangleMesh {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((segmentsAlong + 1) * segmentsAround)
        for i in 0...segmentsAlong {
            let x = length * Float(i) / Float(segmentsAlong)
            let centreZ = topZ(x) - radius
            for j in 0..<segmentsAround {
                let theta = 2 * Float.pi * Float(j) / Float(segmentsAround)
                let y = radius * sin(theta)
                let z = centreZ + radius * cos(theta)
                positions.append(SIMD3<Float>(x, y, z))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(segmentsAlong * segmentsAround * 6)
        for i in 0..<segmentsAlong {
            for j in 0..<segmentsAround {
                let jNext = (j + 1) % segmentsAround
                let a = UInt32(i * segmentsAround + j)
                let b = UInt32(i * segmentsAround + jNext)
                let c = UInt32((i + 1) * segmentsAround + j)
                let d = UInt32((i + 1) * segmentsAround + jNext)
                indices.append(contentsOf: [a, c, b])
                indices.append(contentsOf: [b, c, d])
            }
        }
        return TriangleMesh(positions: positions, indices: indices)
    }
}
