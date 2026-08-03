import Foundation
import simd

/// A transverse cross-section of the back at one station (Design §9). The main
/// polyline is expressed both in 3D (normalized frame) and in a 2D local plane
/// frame `(u, v)` where `u` is horizontal-lateral (0 at the spine) and `v` is
/// vertical (0 at the spine level, increasing upward).
public struct CrossSection: Sendable {
    public let stationIndex: Int
    public let arcLength: Double
    /// Spine point `S(sᵢ)` — the 2D frame origin.
    public let origin: SIMD3<Double>
    /// Cutting-plane normal `T(sᵢ)` (spine tangent).
    public let normal: SIMD3<Double>
    /// In-plane horizontal-lateral axis.
    public let uAxis: SIMD3<Double>
    /// In-plane vertical axis.
    public let vAxis: SIMD3<Double>
    public let points3D: [SIMD3<Double>]
    public let points2D: [SIMD2<Double>]
    public let isClosed: Bool
}

/// Intersects a plane with a triangle mesh, returning line segments (Design §9.3).
public enum PlaneMeshIntersector {

    /// Line segments where the plane `(point, normal)` crosses `mesh`, each as a
    /// pair of 3D endpoints.
    public static func intersect(
        _ mesh: TriangleMesh, planePoint P: SIMD3<Double>, planeNormal N: SIMD3<Double>
    ) -> [(SIMD3<Double>, SIMD3<Double>)] {
        var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
        let n = simd_normalize(N)

        for t in 0..<mesh.triangleCount {
            let (fa, fb, fc) = mesh.triangle(t)
            let v = [SIMD3<Double>(fa), SIMD3<Double>(fb), SIMD3<Double>(fc)]
            let d = v.map { simd_dot($0 - P, n) }

            // Collect intersection points on edges whose endpoints straddle the plane.
            var crossings: [SIMD3<Double>] = []
            for (a, b) in [(0, 1), (1, 2), (2, 0)] {
                let da = d[a], db = d[b]
                if (da < 0 && db > 0) || (da > 0 && db < 0) {
                    let s = da / (da - db)
                    crossings.append(v[a] + s * (v[b] - v[a]))
                }
            }
            if crossings.count == 2 {
                segments.append((crossings[0], crossings[1]))
            }
        }
        return segments
    }
}

/// Extracts cross-sections at evenly spaced stations along the ROI (Design §9.2).
public enum CrossSectionExtractor {

    public struct Configuration: Sendable {
        /// Station spacing along arc length (Design §9.2: default 2 cm, 1–5 cm).
        public var spacing: Double = 0.02
        /// Endpoint weld tolerance for polyline assembly.
        public var weldTolerance: Double = 5e-4
        /// Discard assembled polylines shorter than this (noise loops).
        public var minPolylineLength: Double = 0.05
        /// If set, clip each section to `±lateralHalfWidth` (metres) from the
        /// spine (u = 0). Keeps the saddle-relevant span and lets sections print
        /// at true scale on a fixed page (Design §9).
        public var lateralHalfWidth: Double?
        public init() {}
    }

    /// Extracts one `CrossSection` per station over `roiArcLength`, uniformly
    /// spaced. The mesh should already be ROI-cropped.
    public static func extract(
        _ mesh: TriangleMesh,
        curve: SpineCurve,
        roiArcLength roi: ClosedRange<Double>,
        configuration cfg: Configuration = Configuration()
    ) -> [CrossSection] {
        let count = max(Int(((roi.upperBound - roi.lowerBound) / cfg.spacing).rounded(.down)) + 1, 1)
        let stations = (0..<count)
            .map { roi.lowerBound + Double($0) * cfg.spacing }
            .filter { $0 <= roi.upperBound }
        return extract(mesh, curve: curve, atArcLengths: stations, configuration: cfg)
    }

    /// Extracts a `CrossSection` at each of the given spine arc lengths, in order.
    /// Station indices follow the array order, so callers control station 0 (e.g.
    /// the withers). The mesh should already be ROI-cropped.
    public static func extract(
        _ mesh: TriangleMesh,
        curve: SpineCurve,
        atArcLengths stations: [Double],
        configuration cfg: Configuration = Configuration()
    ) -> [CrossSection] {
        let worldUp = SIMD3<Double>(0, 0, 1)
        var sections: [CrossSection] = []

        for (i, s) in stations.enumerated() {
            let origin = curve.point(atArcLength: s)
            let normal = curve.tangent(atArcLength: s)

            // In-plane frame: u horizontal-lateral, v vertical.
            var uAxis = simd_cross(worldUp, normal)
            if simd_length(uAxis) < 1e-6 { uAxis = SIMD3<Double>(0, 1, 0) }
            uAxis = simd_normalize(uAxis)
            var vAxis = simd_normalize(simd_cross(normal, uAxis))
            // Force v to point up (world +Z). Otherwise its sign flips where the
            // spine tangent's vertical component changes sign (across the
            // withers), inverting the section and the tree-angle signs.
            if vAxis.z < 0 { vAxis = -vAxis }

            let segments = PlaneMeshIntersector.intersect(mesh, planePoint: origin, planeNormal: normal)
            guard let (poly, closed) = mainPolyline(from: segments, cfg: cfg) else { continue }

            let fullPoints2D = poly.map { p -> SIMD2<Double> in
                let rel = p - origin
                return SIMD2<Double>(simd_dot(rel, uAxis), simd_dot(rel, vAxis))
            }

            var points2D = fullPoints2D
            var isClosed = closed
            if let halfWidth = cfg.lateralHalfWidth {
                points2D = clipLaterally(fullPoints2D, halfWidth: halfWidth)
                guard points2D.count >= 2 else { continue }
                isClosed = closed && points2D.count == fullPoints2D.count
            }

            sections.append(CrossSection(
                stationIndex: i, arcLength: s, origin: origin, normal: normal,
                uAxis: uAxis, vAxis: vAxis, points3D: poly, points2D: points2D, isClosed: isClosed
            ))
        }
        return sections
    }

    /// Clips a section polyline to the vertical strip `|u| ≤ halfWidth`,
    /// interpolating points where it crosses the ±halfWidth boundaries.
    private static func clipLaterally(_ pts: [SIMD2<Double>], halfWidth: Double) -> [SIMD2<Double>] {
        guard pts.count > 1 else { return pts.filter { abs($0.x) <= halfWidth } }
        let bounds = [-halfWidth, halfWidth]
        var out: [SIMD2<Double>] = []
        for i in 0..<pts.count {
            let p = pts[i]
            if i > 0 {
                let q = pts[i - 1]
                var crossings: [(t: Double, point: SIMD2<Double>)] = []
                for b in bounds where (q.x - b) * (p.x - b) < 0 {
                    let t = (b - q.x) / (p.x - q.x)
                    crossings.append((t, SIMD2<Double>(b, q.y + t * (p.y - q.y))))
                }
                for crossing in crossings.sorted(by: { $0.t < $1.t }) { out.append(crossing.point) }
            }
            if abs(p.x) <= halfWidth { out.append(p) }
        }
        return out
    }

    /// Assembles segments into polylines by welding shared endpoints, returning
    /// the longest one (the back cross-section) and whether it is closed.
    private static func mainPolyline(
        from segments: [(SIMD3<Double>, SIMD3<Double>)], cfg: Configuration
    ) -> (points: [SIMD3<Double>], closed: Bool)? {
        guard !segments.isEmpty else { return nil }

        func key(_ p: SIMD3<Double>) -> SIMD3<Int> {
            let s = p / cfg.weldTolerance
            return SIMD3<Int>(Int(s.x.rounded()), Int(s.y.rounded()), Int(s.z.rounded()))
        }

        // Weld endpoints into nodes.
        var nodeID: [SIMD3<Int>: Int] = [:]
        var coords: [SIMD3<Double>] = []
        func node(_ p: SIMD3<Double>) -> Int {
            let k = key(p)
            if let id = nodeID[k] { return id }
            let id = coords.count
            nodeID[k] = id
            coords.append(p)
            return id
        }

        var adjacency: [[(edge: Int, other: Int)]] = []
        func ensure(_ id: Int) { while adjacency.count <= id { adjacency.append([]) } }

        var edges: [(Int, Int)] = []
        for (p, q) in segments {
            let a = node(p), b = node(q)
            if a == b { continue }
            let e = edges.count
            edges.append((a, b))
            ensure(a); ensure(b)
            adjacency[a].append((e, b))
            adjacency[b].append((e, a))
        }
        guard !edges.isEmpty else { return nil }

        // Walk chains, consuming each edge once.
        var used = [Bool](repeating: false, count: edges.count)
        var chains: [[Int]] = []
        for startEdge in 0..<edges.count where !used[startEdge] {
            let start = edges[startEdge].0
            var chain = [start]
            var current = start
            while true {
                guard let step = adjacency[current].first(where: { !used[$0.edge] }) else { break }
                used[step.edge] = true
                current = step.other
                chain.append(current)
                if current == start { break }   // closed loop
            }
            chains.append(chain)
        }

        // Pick the longest chain by cumulative 3D length.
        func length(_ chain: [Int]) -> Double {
            var l = 0.0
            for i in 1..<max(chain.count, 1) { l += simd_distance(coords[chain[i]], coords[chain[i - 1]]) }
            return l
        }
        // Stitch chains that were split at a shared junction node (a self-touch
        // of the section, common at the withers) back into one polyline.
        chains = stitch(chains, coords: coords, tolerance: cfg.weldTolerance * 4)

        guard let best = chains.max(by: { length($0) < length($1) }), best.count >= 2 else { return nil }
        if length(best) < cfg.minPolylineLength { return nil }

        let closed = best.first == best.last
        let points = best.map { coords[$0] }
        return (points, closed)
    }

    /// Greedily joins polyline fragments whose endpoints coincide (within
    /// `tolerance`), repairing loops that the edge-walk split at junctions.
    private static func stitch(_ input: [[Int]], coords: [SIMD3<Double>], tolerance: Double) -> [[Int]] {
        var pieces = input.filter { $0.count >= 2 }
        func near(_ a: Int, _ b: Int) -> Bool { simd_distance(coords[a], coords[b]) <= tolerance }

        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<pieces.count {
                for j in (i + 1)..<pieces.count {
                    let a = pieces[i], b = pieces[j]
                    let joined: [Int]?
                    if near(a[a.count - 1], b[0]) { joined = a + b.dropFirst() }
                    else if near(a[a.count - 1], b[b.count - 1]) { joined = a + b.reversed().dropFirst() }
                    else if near(a[0], b[0]) { joined = a.reversed() + b.dropFirst() }
                    else if near(a[0], b[b.count - 1]) { joined = b + a.dropFirst() }
                    else { joined = nil }

                    if let joined {
                        pieces[i] = joined
                        pieces.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return pieces
    }
}
