import Foundation
import simd

/// Per-station saddle-fitting metrics (Design §9.4, decision M-2 ships the full
/// set). All lengths in metres, angles in degrees. The 2D conventions follow
/// `CrossSection`: `u` horizontal-lateral (0 at spine), `v` vertical (0 at spine
/// level, up positive).
public struct SectionMetrics: Sendable {
    public let stationIndex: Int
    public let arcLength: Double
    /// Horizontal extent of the section at spine level (v = 0).
    public let widthAtSpineLevel: Double
    /// Drop from spine level to the lowest point of the section.
    public let depthBelowSpine: Double
    /// RMS left/right asymmetry of the section width (mirror test).
    public let symmetricErrorRMS: Double
    /// Tree angle on the left, at a fixed lateral distance from the spine.
    public let angleLeftDegrees: Double
    /// Tree angle on the right, at a fixed lateral distance from the spine.
    public let angleRightDegrees: Double
    /// Curvature of the spine curve at this station (the back's "rock").
    public let curvatureAlongSpine: Double
    /// Whether the tree angles are trustworthy: the section reaches the lateral
    /// angle distance (±5 cm) on both sides of the spine, so `angleLeftDegrees`
    /// and `angleRightDegrees` are finite. Saddle cross-sections are open arcs,
    /// so this — not closedness — is the reliability test. Sections that fall
    /// short on a side (e.g. near the front cutoff) are flagged unreliable with
    /// `NaN` tree angles; `depthBelowSpine` and `curvatureAlongSpine` stay valid.
    public let isReliable: Bool
}

public enum SectionMetricsCalculator {

    public struct Configuration: Sendable {
        /// Lateral distance from the spine at which tree angles are measured.
        public var lateralAngleDistance: Double = 0.05
        /// Finite-difference step for the tree-angle slope.
        public var angleDelta: Double = 0.01
        /// Number of vertical levels sampled for the symmetry metric.
        public var symmetrySamples: Int = 24
        /// Arc-length step for spine curvature.
        public var curvatureDelta: Double = 0.01
        public init() {}
    }

    public static func metrics(
        for section: CrossSection, curve: SpineCurve, configuration cfg: Configuration = Configuration()
    ) -> SectionMetrics {
        let pts = section.points2D

        // Width at spine level (v = 0).
        let atZero = crossings(of: pts, level: 0, axis: .horizontal)
        let width = atZero.count >= 2 ? (atZero.max()! - atZero.min()!) : 0

        // Depth below the spine.
        let minV = pts.map(\.y).min() ?? 0
        let depth = max(-minV, 0)

        // Symmetry: RMS of (minU + maxU) sampled over vertical levels where the
        // section spans both sides.
        var sqSum = 0.0, sqCount = 0
        if depth > 1e-4 {
            for i in 1...cfg.symmetrySamples {
                let level = -depth * Double(i) / Double(cfg.symmetrySamples + 1)
                let us = crossings(of: pts, level: level, axis: .horizontal)
                guard let lo = us.min(), let hi = us.max(), us.count >= 2 else { continue }
                sqSum += (lo + hi) * (lo + hi)
                sqCount += 1
            }
        }
        let symmetry = sqCount > 0 ? (sqSum / Double(sqCount)).squareRoot() : 0

        // Tree angles from the slope of the upper profile at ±lateralAngleDistance.
        // NaN if the section doesn't reach that lateral distance on a side —
        // saddle cross-sections are open arcs, so this, not closedness, is the
        // right reliability test.
        let d = cfg.lateralAngleDistance, delta = cfg.angleDelta
        let angleRight = treeAngle(of: pts, atU: d, delta: delta, side: .right)
        let angleLeft = treeAngle(of: pts, atU: -d, delta: delta, side: .left)

        // Spine curvature (rate of tangent change along arc length).
        let s = section.arcLength
        let sLo = max(s - cfg.curvatureDelta, 0)
        let sHi = min(s + cfg.curvatureDelta, curve.totalArcLength)
        let curvature = sHi > sLo
            ? simd_length(curve.tangent(atArcLength: sHi) - curve.tangent(atArcLength: sLo)) / (sHi - sLo)
            : 0

        let reliable = angleLeft.isFinite && angleRight.isFinite

        return SectionMetrics(
            stationIndex: section.stationIndex, arcLength: section.arcLength,
            widthAtSpineLevel: width, depthBelowSpine: depth, symmetricErrorRMS: symmetry,
            angleLeftDegrees: angleLeft, angleRightDegrees: angleRight,
            curvatureAlongSpine: curvature, isReliable: reliable
        )
    }

    // MARK: - Geometry helpers

    private enum Axis { case horizontal, vertical }
    private enum Side { case left, right }

    /// Coordinates where the polyline crosses a constant `level`. For
    /// `.horizontal` the level is a `v` value and returned values are `u`
    /// crossings; for `.vertical` it is a `u` value returning `v` crossings.
    private static func crossings(of pts: [SIMD2<Double>], level: Double, axis: Axis) -> [Double] {
        var out: [Double] = []
        guard pts.count >= 2 else { return out }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let (pa, pb) = axis == .horizontal ? (a.y, b.y) : (a.x, b.x)
            if (pa - level) * (pb - level) < 0 {
                let t = (level - pa) / (pb - pa)
                out.append(axis == .horizontal ? a.x + t * (b.x - a.x) : a.y + t * (b.y - a.y))
            }
        }
        return out
    }

    /// The upper profile height at a vertical line `u`.
    private static func upperV(of pts: [SIMD2<Double>], atU u: Double) -> Double? {
        crossings(of: pts, level: u, axis: .vertical).max()
    }

    /// Tree angle (degrees below horizontal, positive descending outward) from
    /// the upper-profile slope at lateral position `atU`.
    private static func treeAngle(of pts: [SIMD2<Double>], atU u: Double, delta: Double, side: Side) -> Double {
        guard let hiOuter = upperV(of: pts, atU: side == .right ? u + delta : u - delta),
              let hiInner = upperV(of: pts, atU: side == .right ? u - delta : u + delta)
        else { return .nan }
        // Slope of the surface moving outward (away from the spine).
        let slopeOutward = (hiOuter - hiInner) / (2 * delta)
        return atan(-slopeOutward) * 180 / .pi
    }
}
