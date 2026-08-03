import Foundation

/// A natural cubic **smoothing** spline (curvature-penalized least squares).
///
/// Fits `y(x)` through weighted data by minimizing
/// `Σ wᵢ (yᵢ − g(xᵢ))² + λ ∫ g''(x)² dx`, where `wᵢ = 1/σᵢ²`. Solved via the
/// Green–Silverman reduced system (Reinsch algorithm). Used by
/// `SpineCurveFitter` to suppress the coarse mesh's mm-scale noise (Design §7.2).
///
/// The smoothing amount `λ` can be supplied directly or chosen automatically to
/// meet the χ²≈n criterion — i.e. so the weighted residual sum matches the
/// number of points, given per-point noise estimates `σᵢ`.
public struct SmoothingSpline: Sendable {
    /// Sorted, strictly increasing knot abscissae.
    public let x: [Double]
    /// Fitted values at the knots.
    public let g: [Double]
    /// Second derivatives at the knots (natural boundary: ends are 0).
    public let m: [Double]
    /// Smoothing parameter actually used.
    public let lambda: Double
    /// Weighted residual sum of squares `Σ ((yᵢ − gᵢ)/σᵢ)²`.
    public let weightedRSS: Double

    // MARK: Evaluation

    /// Evaluates the spline at `xq`, clamping to the fitted x-range.
    public func value(at xq: Double) -> Double {
        let (j, h, a, b) = segment(for: xq)
        return a * g[j] + b * g[j + 1]
            + ((a * a * a - a) * m[j] + (b * b * b - b) * m[j + 1]) * h * h / 6
    }

    /// Evaluates the first derivative `dy/dx` at `xq`.
    public func derivative(at xq: Double) -> Double {
        let (j, h, a, b) = segment(for: xq)
        return (g[j + 1] - g[j]) / h
            - (3 * a * a - 1) / 6 * h * m[j]
            + (3 * b * b - 1) / 6 * h * m[j + 1]
    }

    /// Locates the segment containing `xq` and returns its index and the
    /// standard cubic-spline blend coefficients.
    private func segment(for xq: Double) -> (j: Int, h: Double, a: Double, b: Double) {
        let clamped = min(max(xq, x[0]), x[x.count - 1])
        // Binary search for the segment [x[j], x[j+1]].
        var lo = 0, hi = x.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if x[mid] > clamped { hi = mid } else { lo = mid }
        }
        let h = x[lo + 1] - x[lo]
        let a = (x[lo + 1] - clamped) / h
        let b = (clamped - x[lo]) / h
        return (lo, h, a, b)
    }
}

// MARK: - Fitting

extension SmoothingSpline {

    /// Fits with an explicit smoothing parameter `lambda`.
    public static func fit(x: [Double], y: [Double], sigma: [Double], lambda: Double) -> SmoothingSpline {
        precondition(x.count == y.count && x.count == sigma.count)
        let system = PenaltySystem(x: x, y: y, sigma: sigma)
        return system.solve(lambda: lambda)
    }

    /// Fits, choosing `lambda` automatically so the weighted residual sum of
    /// squares meets `residualTarget` (default: the point count `n`, the
    /// standard Reinsch χ²≈n criterion). Clean data (tiny `σ`) drives `λ` toward
    /// interpolation; noisy data increases smoothing.
    public static func autoFit(
        x: [Double], y: [Double], sigma: [Double], residualTarget: Double? = nil
    ) -> SmoothingSpline {
        precondition(x.count == y.count && x.count == sigma.count)
        let n = x.count
        let target = residualTarget ?? Double(n)
        let system = PenaltySystem(x: x, y: y, sigma: sigma)

        // weightedRSS is monotonically increasing in λ. Bisect in log-space.
        var loExp = -8.0, hiExp = 8.0
        let rssLo = system.solve(lambda: pow(10, loExp)).weightedRSS
        if rssLo >= target { return system.solve(lambda: pow(10, loExp)) }
        let rssHi = system.solve(lambda: pow(10, hiExp)).weightedRSS
        if rssHi <= target { return system.solve(lambda: pow(10, hiExp)) }

        var best = system.solve(lambda: pow(10, hiExp))
        for _ in 0..<48 {
            let midExp = (loExp + hiExp) / 2
            best = system.solve(lambda: pow(10, midExp))
            // A NaN residual means the solve went numerically unstable at this λ;
            // treat it as "too smooth" and search lower.
            if best.weightedRSS.isNaN || best.weightedRSS > target { hiExp = midExp } else { loExp = midExp }
        }
        if best.weightedRSS.isNaN { best = system.solve(lambda: pow(10, loExp)) }
        return best
    }
}

/// Precomputes the λ-independent pieces of the smoothing-spline linear system so
/// that repeated solves (during the automatic-λ search) only re-form and factor
/// the small `(n-2)×(n-2)` matrix.
private struct PenaltySystem {
    let x: [Double]
    let y: [Double]
    let sigma: [Double]
    let n: Int
    let h: [Double]                 // knot spacings, count n-1
    let R: [[Double]]               // (n-2)×(n-2) tridiagonal penalty matrix
    let QtDQ: [[Double]]            // (n-2)×(n-2) = Qᵀ diag(σ²) Q
    let Qty: [Double]               // length n-2
    let dSquared: [Double]          // σ²

    init(x: [Double], y: [Double], sigma: [Double]) {
        self.x = x; self.y = y; self.sigma = sigma
        self.n = x.count
        let sig2 = sigma.map { max($0 * $0, 1e-16) }
        self.dSquared = sig2

        var hh = [Double](repeating: 0, count: max(n - 1, 0))
        for i in 0..<(n - 1) { hh[i] = x[i + 1] - x[i] }
        self.h = hh

        let m = max(n - 2, 0)

        // Dense Q (n × m). Column c corresponds to interior knot i = c+1.
        var Q = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for c in 0..<m {
            let i = c + 1
            Q[i - 1][c] = 1 / hh[i - 1]
            Q[i][c] = -1 / hh[i - 1] - 1 / hh[i]
            Q[i + 1][c] = 1 / hh[i]
        }

        // R (m × m) symmetric tridiagonal.
        var Rmat = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for c in 0..<m {
            let i = c + 1
            Rmat[c][c] = (hh[i - 1] + hh[i]) / 3
            if c + 1 < m { Rmat[c][c + 1] = hh[i] / 6; Rmat[c + 1][c] = hh[i] / 6 }
        }
        self.R = Rmat

        // QᵀDQ and Qᵀy.
        var A = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var rhs = [Double](repeating: 0, count: m)
        for c in 0..<m {
            for cp in 0..<m {
                var s = 0.0
                for row in 0..<n { s += Q[row][c] * sig2[row] * Q[row][cp] }
                A[c][cp] = s
            }
            var s = 0.0
            for row in 0..<n { s += Q[row][c] * y[row] }
            rhs[c] = s
        }
        self.QtDQ = A
        self.Qty = rhs
        self.Qdense = Q
    }

    let Qdense: [[Double]]

    /// Solves the system for a given `lambda`, returning the fitted spline.
    func solve(lambda: Double) -> SmoothingSpline {
        let m = n - 2
        // Degenerate cases: too few points for an interior knot → straight/flat.
        guard m >= 1 else {
            let g = y
            let mm = [Double](repeating: 0, count: n)
            let rss = zip(zip(y, g), sigma).reduce(0.0) { acc, t in
                let ((yi, gi), si) = t
                let s = max(si, 1e-8)
                return acc + ((yi - gi) / s) * ((yi - gi) / s)
            }
            return SmoothingSpline(x: x, g: g, m: mm, lambda: lambda, weightedRSS: rss)
        }

        // M = R + λ QᵀDQ.
        var M = R
        for i in 0..<m {
            for j in 0..<m { M[i][j] += lambda * QtDQ[i][j] }
        }
        let gamma = solveSPD(M, Qty)

        // g = y − λ diag(σ²) Q γ.
        var g = y
        for row in 0..<n {
            var qg = 0.0
            for c in 0..<m { qg += Qdense[row][c] * gamma[c] }
            g[row] = y[row] - lambda * dSquared[row] * qg
        }

        // Second derivatives at knots: interior = γ, natural ends = 0.
        var mm = [Double](repeating: 0, count: n)
        for c in 0..<m { mm[c + 1] = gamma[c] }

        let rss = (0..<n).reduce(0.0) { acc, i in
            let s = max(sigma[i], 1e-8)
            let r = (y[i] - g[i]) / s
            return acc + r * r
        }
        return SmoothingSpline(x: x, g: g, m: mm, lambda: lambda, weightedRSS: rss)
    }
}

/// Solves `A x = b` for a symmetric positive-definite dense matrix via Cholesky.
private func solveSPD(_ A: [[Double]], _ b: [Double]) -> [Double] {
    let n = b.count
    var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n {
        for j in 0...i {
            var sum = A[i][j]
            for k in 0..<j { sum -= L[i][k] * L[j][k] }
            if i == j {
                L[i][j] = Swift.max(sum, 1e-18).squareRoot()
            } else {
                L[i][j] = sum / L[j][j]
            }
        }
    }
    // Forward solve L z = b.
    var z = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var sum = b[i]
        for k in 0..<i { sum -= L[i][k] * z[k] }
        z[i] = sum / L[i][i]
    }
    // Back solve Lᵀ x = z.
    var xOut = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var sum = z[i]
        for k in (i + 1)..<n where k < n { sum -= L[k][i] * xOut[k] }
        xOut[i] = sum / L[i][i]
    }
    return xOut
}
