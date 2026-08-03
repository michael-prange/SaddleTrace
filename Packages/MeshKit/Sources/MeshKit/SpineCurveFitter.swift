import Foundation
import simd

/// The fitted dorsal spine curve `S(x) → (y, z)` over the animal's long axis,
/// with arc-length parameterization (Design §7.2). The curve is expressed in the
/// normalized Z-up frame (long axis = +X). Head/tail sign is resolved separately
/// by `LandmarkDetector`.
public struct SpineCurve: Sendable {
    /// Lateral offset of the crest as a function of X.
    public let ySpline: SmoothingSpline
    /// Dorsal height of the crest as a function of X.
    public let zSpline: SmoothingSpline
    public let xMin: Double
    public let xMax: Double

    // Arc-length lookup table (monotone), sampled uniformly in X.
    private let sampleX: [Double]
    private let cumulativeS: [Double]
    private let samplePoint: [SIMD3<Double>]

    init(ySpline: SmoothingSpline, zSpline: SmoothingSpline, xMin: Double, xMax: Double) {
        self.ySpline = ySpline
        self.zSpline = zSpline
        self.xMin = xMin
        self.xMax = xMax

        // Build the arc-length table at ~1 mm resolution.
        let span = max(xMax - xMin, 1e-6)
        let count = max(Int((span / 0.001).rounded()) + 1, 2)
        var xs = [Double](repeating: 0, count: count)
        var ss = [Double](repeating: 0, count: count)
        var pts = [SIMD3<Double>](repeating: .zero, count: count)
        var prev = SIMD3<Double>(xMin, ySpline.value(at: xMin), zSpline.value(at: xMin))
        xs[0] = xMin; ss[0] = 0; pts[0] = prev
        for i in 1..<count {
            let x = xMin + span * Double(i) / Double(count - 1)
            let p = SIMD3<Double>(x, ySpline.value(at: x), zSpline.value(at: x))
            ss[i] = ss[i - 1] + simd_distance(p, prev)
            xs[i] = x
            pts[i] = p
            prev = p
        }
        self.sampleX = xs
        self.cumulativeS = ss
        self.samplePoint = pts
    }

    /// The closest point on the curve to `p`, returned as its arc length and the
    /// 3D Euclidean distance. Uses the ~1 mm sample table (sub-mm accuracy),
    /// which is ample for ROI cropping (Design §7.4).
    public func closestPoint(to p: SIMD3<Double>) -> (arcLength: Double, distance: Double) {
        var bestI = 0
        var bestSq = Double.infinity
        for i in 0..<samplePoint.count {
            let d = simd_distance_squared(samplePoint[i], p)
            if d < bestSq { bestSq = d; bestI = i }
        }
        return (cumulativeS[bestI], bestSq.squareRoot())
    }

    /// Total arc length of the curve.
    public var totalArcLength: Double { cumulativeS[cumulativeS.count - 1] }

    /// The 3D spine point at abscissa `x`.
    public func point(atX x: Double) -> SIMD3<Double> {
        SIMD3<Double>(x, ySpline.value(at: x), zSpline.value(at: x))
    }

    /// Dorsal height (Z) at abscissa `x`.
    public func height(atX x: Double) -> Double { zSpline.value(at: x) }

    /// Unit tangent (direction of increasing X) at abscissa `x`.
    public func tangent(atX x: Double) -> SIMD3<Double> {
        let d = SIMD3<Double>(1, ySpline.derivative(at: x), zSpline.derivative(at: x))
        return simd_normalize(d)
    }

    /// Arc length from `xMin` to abscissa `x`.
    public func arcLength(atX x: Double) -> Double {
        interpolate(query: min(max(x, xMin), xMax), from: sampleX, to: cumulativeS)
    }

    /// The abscissa `x` at a given arc length `s` from `xMin`.
    public func x(atArcLength s: Double) -> Double {
        interpolate(query: min(max(s, 0), totalArcLength), from: cumulativeS, to: sampleX)
    }

    /// The 3D spine point at arc length `s`.
    public func point(atArcLength s: Double) -> SIMD3<Double> { point(atX: x(atArcLength: s)) }

    /// Unit tangent at arc length `s`.
    public func tangent(atArcLength s: Double) -> SIMD3<Double> { tangent(atX: x(atArcLength: s)) }

    /// Linear interpolation over a monotone-increasing `from` table.
    private func interpolate(query: Double, from: [Double], to: [Double]) -> Double {
        if query <= from[0] { return to[0] }
        if query >= from[from.count - 1] { return to[to.count - 1] }
        var lo = 0, hi = from.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if from[mid] > query { hi = mid } else { lo = mid }
        }
        let t = (query - from[lo]) / (from[lo + 1] - from[lo])
        return to[lo] + t * (to[lo + 1] - to[lo])
    }
}

/// Fits the spine curve from a mesh using "slice-and-find-peaks" (Design §7.2):
/// step vertical planes along the long axis, take the highest vertex in each
/// slab, then fit noise-weighted smoothing splines through the peaks.
///
/// The input mesh must already be normalized (long axis = +X); see
/// `LongAxisNormalizer`.
public enum SpineCurveFitter {

    public struct Configuration: Sendable {
        /// Spacing between slice planes along X.
        public var sliceSpacing: Float = 0.02
        /// Half-width of the slab gathered around each slice plane.
        public var slabHalfWidth: Float = 0.01
        /// Vertices at or below this Z are treated as legs/ground and ignored.
        public var topRegionMinHeight: Float = 0.8
        /// Lateral window around the crest used to estimate vertical noise.
        public var crestLateralWindow: Float = 0.05
        /// Lower bound on estimated per-slice noise (metres).
        public var noiseFloor: Float = 1e-4
        public init() {}
    }

    public struct Result: Sendable {
        /// Raw per-slice peak points (highest vertex in each slab).
        public let peaks: [SIMD3<Float>]
        public let curve: SpineCurve
    }

    /// Fits the spine curve. Returns `nil` if too few slices contain data.
    public static func fit(_ mesh: TriangleMesh, configuration: Configuration = Configuration()) -> Result? {
        let cfg = configuration
        let top = mesh.positions.filter { $0.z > cfg.topRegionMinHeight }
        guard top.count >= 8 else { return nil }

        let xLo = top.min { $0.x < $1.x }!.x
        let xHi = top.max { $0.x < $1.x }!.x
        guard xHi - xLo > cfg.sliceSpacing else { return nil }

        // Bucket vertices into slabs by X for O(n) slicing.
        let sliceCount = max(Int(((xHi - xLo) / cfg.sliceSpacing).rounded(.down)) + 1, 2)

        var peaks: [SIMD3<Float>] = []
        var xs: [Double] = [], ys: [Double] = [], zs: [Double] = []
        var sigY: [Double] = [], sigZ: [Double] = []

        for s in 0..<sliceCount {
            let xc = xLo + Float(s) * cfg.sliceSpacing
            let slab = top.filter { abs($0.x - xc) <= cfg.slabHalfWidth }
            guard let peak = slab.max(by: { $0.z < $1.z }) else { continue }

            // Vertical-noise estimate: scatter of Z among near-crest vertices.
            let nearCrest = slab.filter { abs($0.y - peak.y) <= cfg.crestLateralWindow }
            let zNoise = Self.standardDeviation(nearCrest.map { $0.z }, floor: cfg.noiseFloor)
            // Lateral-position noise: scatter of Y among the topmost vertices.
            let topBand = slab.filter { $0.z >= peak.z - 0.02 }
            let yNoise = Self.standardDeviation(topBand.map { $0.y }, floor: cfg.noiseFloor)

            peaks.append(peak)
            // Use the slice-centre X as the knot abscissa — it increases strictly
            // by `sliceSpacing`, whereas the picked vertex's grid-quantized X can
            // repeat between adjacent slabs (duplicate knots → singular spline).
            xs.append(Double(xc))
            ys.append(Double(peak.y))
            zs.append(Double(peak.z))
            sigY.append(Double(yNoise))
            sigZ.append(Double(zNoise))
        }

        guard xs.count >= 4 else { return nil }

        let ySpline = SmoothingSpline.autoFit(x: xs, y: ys, sigma: sigY)
        let zSpline = SmoothingSpline.autoFit(x: xs, y: zs, sigma: sigZ)
        let curve = SpineCurve(ySpline: ySpline, zSpline: zSpline, xMin: xs.first!, xMax: xs.last!)
        return Result(peaks: peaks, curve: curve)
    }

    private static func standardDeviation(_ values: [Float], floor: Float) -> Float {
        guard values.count >= 2 else { return floor }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return max(variance.squareRoot(), floor)
    }
}
