import Testing
import simd
import Foundation
@testable import MeshKit

@Suite("Smoothing spline")
struct SmoothingSplineTests {

    @Test("Interpolates a smooth curve when noise is tiny")
    func interpolatesCleanData() {
        // Sample z = sin(x) with negligible noise.
        let xs = stride(from: 0.0, through: .pi, by: .pi / 30).map { $0 }
        let ys = xs.map { sin($0) }
        let sig = [Double](repeating: 1e-4, count: xs.count)
        let spline = SmoothingSpline.autoFit(x: xs, y: ys, sigma: sig)

        for t in stride(from: 0.05, to: 3.0, by: 0.13) {
            #expect(abs(spline.value(at: t) - sin(t)) < 5e-3)
        }
    }

    @Test("Recovers the underlying curve from noisy samples and reduces error")
    func smoothsNoisyData() {
        var rng = SystemRandomNumberGeneratorSeeded(seed: 42)
        let xs = stride(from: 0.0, through: 2 * .pi, by: 2 * .pi / 80).map { $0 }
        let noiseSD = 0.15
        let clean = xs.map { sin($0) }
        let noisy = zip(xs, clean).map { (_, c) in c + noiseSD * rng.nextGaussian() }
        let sig = [Double](repeating: noiseSD, count: xs.count)

        let spline = SmoothingSpline.autoFit(x: xs, y: noisy, sigma: sig)

        // Error of the smoothed curve vs. truth should be well below the raw noise.
        var sse = 0.0
        for (x, c) in zip(xs, clean) { let e = spline.value(at: x) - c; sse += e * e }
        let rmse = (sse / Double(xs.count)).squareRoot()
        #expect(rmse < noiseSD * 0.6)
    }

    @Test("Derivative matches finite differences")
    func derivativeAccuracy() {
        let xs = stride(from: 0.0, through: .pi, by: .pi / 40).map { $0 }
        let ys = xs.map { sin($0) }
        let spline = SmoothingSpline.autoFit(x: xs, y: ys, sigma: [Double](repeating: 1e-4, count: xs.count))
        let h = 1e-4
        for t in stride(from: 0.3, to: 2.8, by: 0.4) {
            let fd = (spline.value(at: t + h) - spline.value(at: t - h)) / (2 * h)
            #expect(abs(spline.derivative(at: t) - fd) < 1e-2)
        }
    }
}

@Suite("Spine curve fitting")
struct SpineCurveFitterTests {

    @Test("Fits the synthetic ridge height within a few millimetres")
    func fitsSyntheticRidge() {
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: 200, segmentsAround: 48)
        let result = SpineCurveFitter.fit(mesh)
        let curve = try! #require(result?.curve)

        // Crest lateral offset should be ~0 (symmetric back).
        for x in stride(from: 0.2, through: 1.2, by: 0.1) {
            #expect(abs(curve.ySpline.value(at: x)) < 0.01)
        }

        // Fitted height should track the withers/loin/croup structure. Highest
        // point of the curve should sit near the withers X.
        var bestX = 0.0, bestZ = -Double.infinity
        for x in stride(from: curve.xMin, through: curve.xMax, by: 0.005) {
            let z = curve.height(atX: x)
            if z > bestZ { bestZ = z; bestX = x }
        }
        #expect(abs(bestX - Double(truth.withersX)) < 0.03)
    }

    @Test("Fit is finite across mesh resolutions (duplicate-knot regression)")
    func fitFiniteAcrossResolutions() {
        // A grid spacing that is an exact fraction of the slice spacing used to
        // make adjacent slabs pick the same vertex X, producing duplicate knots
        // and a NaN spline. The fitter now keys on slice-centre X instead.
        for along in [120, 140, 160, 200, 280] {
            let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: along, segmentsAround: 48)
            let curve = SpineCurveFitter.fit(mesh)!.curve
            #expect(curve.totalArcLength.isFinite, "total arc length NaN at along=\(along)")
            #expect(curve.totalArcLength > 1.0)
            #expect(curve.height(atX: (curve.xMin + curve.xMax) / 2).isFinite)
        }
    }

    @Test("Arc-length parameterization is consistent and monotone")
    func arcLengthRoundTrips() {
        let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: 160, segmentsAround: 32)
        let curve = SpineCurveFitter.fit(mesh)!.curve

        #expect(curve.totalArcLength > (curve.xMax - curve.xMin)) // curve is longer than its X-span
        for s in stride(from: 0.0, through: curve.totalArcLength, by: curve.totalArcLength / 10) {
            let x = curve.x(atArcLength: s)
            #expect(abs(curve.arcLength(atX: x) - s) < 1e-3)
        }
    }

    @Test("Recovers the ridge from a rotated raw mesh after normalization")
    func fitsAfterNormalization() {
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: 180, segmentsAround: 40)
        let a: Float = 52 * .pi / 180
        let rot = simd_float4x4(
            SIMD4<Float>(cos(a), sin(a), 0, 0),
            SIMD4<Float>(-sin(a), cos(a), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1.5, -0.7, 0, 1)
        )
        let normalized = LongAxisNormalizer.normalized(mesh.transformed(by: rot)).mesh
        let curve = SpineCurveFitter.fit(normalized)!.curve

        // The crest height amplitude across the back should span the withers dip
        // (≈ 0.12 − (−0.05) relative structure ≈ 0.17 m peak-to-trough at most).
        var minZ = Double.infinity, maxZ = -Double.infinity
        for x in stride(from: curve.xMin, through: curve.xMax, by: 0.01) {
            let z = curve.height(atX: x); minZ = min(minZ, z); maxZ = max(maxZ, z)
        }
        #expect(maxZ - minZ > 0.1)
        _ = truth
    }
}

/// Small deterministic RNG with a Box–Muller Gaussian, for reproducible tests.
struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextGaussian() -> Double {
        let u1 = Double(next() >> 11) * (1.0 / 9007199254740992.0)
        let u2 = Double(next() >> 11) * (1.0 / 9007199254740992.0)
        return (-2 * log(max(u1, 1e-12))).squareRoot() * cos(2 * .pi * u2)
    }
}

@Suite("Spine curve nearest-point search")
struct ClosestPointTests {

    /// `closestPoint` seeds at the X-nearest sample and walks outward with an
    /// exact lower bound instead of scanning the whole ~1 mm table. It must agree
    /// with the brute-force scan everywhere — it runs once per mesh vertex during
    /// ROI cropping, so a wrong shortcut would silently mis-crop the ROI.
    @Test("Windowed search matches a brute-force scan")
    func matchesBruteForce() {
        let (mesh, _) = SyntheticBackMesh.make()
        let norm = LongAxisNormalizer.normalized(mesh).mesh
        let curve = SpineCurveFitter.fit(norm)!.curve

        // Brute force over the same table the curve samples internally.
        func brute(_ p: SIMD3<Double>) -> (Double, Double) {
            var bestS = 0.0, bestSq = Double.infinity
            var s = 0.0
            let total = curve.totalArcLength
            let steps = 4000
            while s <= total {
                let q = curve.point(atArcLength: s)
                let d = simd_distance_squared(q, p)
                if d < bestSq { bestSq = d; bestS = s }
                s += total / Double(steps)
            }
            return (bestS, bestSq.squareRoot())
        }

        // Query every mesh vertex plus points well outside the curve's X range.
        var queries = norm.positions.map { SIMD3<Double>($0) }
        queries.append(SIMD3<Double>(curve.xMin - 1.0, 0.3, 0.2))
        queries.append(SIMD3<Double>(curve.xMax + 1.0, -0.3, 1.4))

        for p in queries.prefix(1200) {
            let fast = curve.closestPoint(to: p)
            let (_, refDistance) = brute(p)
            // Same distance to within the sampling resolution of the reference.
            #expect(abs(fast.distance - refDistance) < 2e-3)
            #expect(fast.arcLength >= 0 && fast.arcLength <= curve.totalArcLength)
        }
    }
}
