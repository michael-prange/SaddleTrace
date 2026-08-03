import Foundation
import simd

/// Topline landmarks extracted from the fitted spine curve (Design §7.3), all in
/// the normalized Z-up frame. Positions are given both as abscissae (X) and as
/// arc lengths along the curve (measured from `xMin`).
public struct Landmarks: Sendable {
    public let withersX: Double
    public let croupX: Double
    public let loinX: Double
    public let tailBaseX: Double

    public let withersPoint: SIMD3<Double>
    public let croupPoint: SIMD3<Double>
    public let loinPoint: SIMD3<Double>
    public let tailBasePoint: SIMD3<Double>

    /// +1 if the caudal (tail) direction is +X, −1 if it is −X. Resolves the
    /// head/tail ambiguity the long-axis PCA left open: the withers are the
    /// global height maximum and lie cranial of the croup.
    public let caudalSign: Double

    public let withersArcLength: Double
    public let tailArcLength: Double
    /// Arc length of the front cutoff — the configured distance cranial of the
    /// withers (Design §7.3 default 15 cm).
    public let frontCutoffArcLength: Double

    /// ROI arc-length span, from the front cutoff to the tail base (Design §7.4).
    public var roiArcLengthRange: ClosedRange<Double> {
        let a = min(frontCutoffArcLength, tailArcLength)
        let b = max(frontCutoffArcLength, tailArcLength)
        return a...b
    }
}

/// Detects topline landmarks on a `SpineCurve`.
public enum LandmarkDetector {

    public struct Configuration: Sendable {
        /// Cranial distance from the withers to the front ROI cutoff.
        public var frontCutoffDistance: Double = 0.15
        /// Minimum separation between the withers and the croup peak.
        public var minPeakSeparation: Double = 0.15
        /// Half-window (in metres) for local-maximum detection along X.
        public var peakWindow: Double = 0.05
        /// Sampling step along X.
        public var sampleStep: Double = 0.002
        public init() {}
    }

    public static func detect(on curve: SpineCurve, configuration: Configuration = Configuration()) -> Landmarks {
        let cfg = configuration
        // Sample the crest height along X.
        let span = curve.xMax - curve.xMin
        let n = max(Int((span / cfg.sampleStep).rounded()) + 1, 3)
        var xs = [Double](repeating: 0, count: n)
        var zs = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = curve.xMin + span * Double(i) / Double(n - 1)
            xs[i] = x
            zs[i] = curve.height(atX: x)
        }

        // Withers: global height maximum.
        var withersI = 0
        for i in 1..<n where zs[i] > zs[withersI] { withersI = i }
        let withersX = xs[withersI]

        // Croup: highest local maximum at least `minPeakSeparation` from withers.
        let windowSamples = max(Int((cfg.peakWindow / cfg.sampleStep).rounded()), 1)
        var croupI: Int? = nil
        for i in windowSamples..<(n - windowSamples) {
            guard abs(xs[i] - withersX) >= cfg.minPeakSeparation else { continue }
            var isLocalMax = true
            for k in 1...windowSamples where zs[i] < zs[i - k] || zs[i] < zs[i + k] {
                isLocalMax = false; break
            }
            if isLocalMax, croupI == nil || zs[i] > zs[croupI!] { croupI = i }
        }
        // Fallback: if no distinct secondary peak, use the farther endpoint.
        let croupIndex = croupI ?? ((withersX - curve.xMin) > (curve.xMax - withersX) ? 0 : n - 1)
        let croupX = xs[croupIndex]

        // Caudal direction points from withers toward croup.
        let caudalSign: Double = croupX >= withersX ? 1 : -1

        // Loin: height minimum strictly between withers and croup.
        let loRange = min(withersI, croupIndex)...max(withersI, croupIndex)
        var loinI = loRange.lowerBound
        for i in loRange where zs[i] < zs[loinI] { loinI = i }
        let loinX = xs[loinI]

        // Tail base: the caudal end of the fitted curve.
        let tailBaseX = caudalSign > 0 ? curve.xMax : curve.xMin

        // Arc lengths.
        let withersS = curve.arcLength(atX: withersX)
        let tailS = curve.arcLength(atX: tailBaseX)
        let total = curve.totalArcLength
        // Cranial is the opposite of caudal, so moving cranially shifts arc
        // length by −caudalSign · distance.
        let frontS = min(max(withersS - caudalSign * cfg.frontCutoffDistance, 0), total)

        return Landmarks(
            withersX: withersX, croupX: croupX, loinX: loinX, tailBaseX: tailBaseX,
            withersPoint: curve.point(atX: withersX),
            croupPoint: curve.point(atX: croupX),
            loinPoint: curve.point(atX: loinX),
            tailBasePoint: curve.point(atX: tailBaseX),
            caudalSign: caudalSign,
            withersArcLength: withersS,
            tailArcLength: tailS,
            frontCutoffArcLength: frontS
        )
    }
}
