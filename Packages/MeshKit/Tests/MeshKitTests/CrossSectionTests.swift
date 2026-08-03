import Testing
import simd
import Foundation
@testable import MeshKit

@Suite("Plane–mesh intersection")
struct PlaneIntersectionTests {

    @Test("A single triangle crossing the plane yields one correct segment")
    func singleTriangle() {
        // Triangle with one vertex below and two above the plane z = 0.
        let mesh = TriangleMesh(
            positions: [
                SIMD3<Float>(0, 0, -1),
                SIMD3<Float>(1, 0, 1),
                SIMD3<Float>(-1, 0, 1),
            ],
            indices: [0, 1, 2]
        )
        let segs = PlaneMeshIntersector.intersect(
            mesh, planePoint: SIMD3<Double>(0, 0, 0), planeNormal: SIMD3<Double>(0, 0, 1)
        )
        #expect(segs.count == 1)
        // Both endpoints lie on z = 0 at the edge midpoints (0.5, 0, 0) and (−0.5, 0, 0).
        let (p, q) = segs[0]
        #expect(abs(p.z) < 1e-9 && abs(q.z) < 1e-9)
        let xs = [p.x, q.x].sorted()
        #expect(abs(xs[0] + 0.5) < 1e-6 && abs(xs[1] - 0.5) < 1e-6)
    }

    @Test("A plane missing the mesh yields no segments")
    func noIntersection() {
        let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: 20, segmentsAround: 12)
        // Plane well beyond the caudal end.
        let segs = PlaneMeshIntersector.intersect(
            mesh, planePoint: SIMD3<Double>(5, 0, 0), planeNormal: SIMD3<Double>(1, 0, 0)
        )
        #expect(segs.isEmpty)
    }
}

@Suite("Cross-section extraction & metrics")
struct CrossSectionTests {

    /// Straight cylinder → spine tangent is +X everywhere → transverse sections
    /// are exact circles of radius 0.28. ROI is set manually (no landmarks).
    private func setup() -> (SpineCurve, ClosedRange<Double>, [CrossSection]) {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 160, segmentsAround: 72)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        let roi = (curve.xMin + 0.1)...(curve.xMax - 0.1)
        let sections = CrossSectionExtractor.extract(mesh, curve: curve, roiArcLength: roi)
        return (curve, roi, sections)
    }

    @Test("Extracts closed circular sections of the expected radius")
    func extractsSections() {
        let (_, roi, sections) = setup()

        // Roughly one section per 2 cm over the ROI.
        let expected = Int((roi.upperBound - roi.lowerBound) / 0.02)
        #expect(abs(sections.count - expected) <= 2)

        // Inspect a mid section: a closed loop of radius ≈ 0.28 centred one
        // radius below the spine (v ≈ −0.28).
        let mid = sections[sections.count / 2]
        #expect(mid.isClosed)
        for p in mid.points2D {
            let r = simd_distance(p, SIMD2<Double>(0, -0.28))
            #expect(abs(r - 0.28) < 0.005)
        }
    }

    @Test("Withers-anchored sections on a profiled back are reliable rooftops")
    func withersAnchoredSectionsAreRooftops() {
        let (mesh, _) = SyntheticBackMesh.make()
        let norm = LongAxisNormalizer.normalized(mesh).mesh
        let curve = SpineCurveFitter.fit(norm)!.curve
        let marks = LandmarkDetector.detect(on: curve)
        var cropCfg = ROICropper.Configuration()
        cropCfg.lateralLimit = 0.5
        let cropped = ROICropper.crop(norm, curve: curve,
                                      roiArcLength: marks.roiArcLengthRange, configuration: cropCfg).mesh

        // Stations from the withers caudally, every 4 inches.
        var stations: [Double] = []
        var s = marks.withersArcLength
        while s <= marks.tailArcLength { stations.append(s); s += 0.1016 }

        let sections = CrossSectionExtractor.extract(cropped, curve: curve, atArcLengths: stations)
        #expect(sections.count >= 8)

        // Every station (including station 0, the withers) is a reliable rooftop:
        // apex near spine level and both tree angles opening downward (positive).
        for section in sections {
            let m = SectionMetricsCalculator.metrics(for: section, curve: curve)
            #expect(m.isReliable, "station \(section.stationIndex) unreliable")
            #expect(m.angleLeftDegrees > 0 && m.angleRightDegrees > 0, "station \(section.stationIndex) inverted")
            let apex = section.points2D.map(\.y).max() ?? -1
            #expect(apex > -0.05 && apex < 0.05, "station \(section.stationIndex) apex off spine: \(apex)")
        }
    }

    @Test("Lateral clip restricts sections to ±halfWidth")
    func lateralClip() {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 160, segmentsAround: 72)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        var cfg = CrossSectionExtractor.Configuration()
        cfg.lateralHalfWidth = 0.2032   // 8 inches
        let sections = CrossSectionExtractor.extract(
            mesh, curve: curve, atArcLengths: [0.3, 0.5, 0.7], configuration: cfg)

        #expect(!sections.isEmpty)
        for section in sections {
            #expect(section.points2D.allSatisfy { abs($0.x) <= 0.2032 + 1e-9 })
            // The clip actually happened (tube radius 0.28 m > 0.2032).
            #expect(section.points2D.contains { abs($0.x) > 0.19 })
        }
    }

    @Test("Explicit-station extraction indexes stations in the given order")
    func extractsAtExplicitStations() {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 160, segmentsAround: 72)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        // Withers-anchored style: start mid-body, step caudally.
        let stations = [0.3, 0.4, 0.5, 0.6, 0.7]
        let sections = CrossSectionExtractor.extract(mesh, curve: curve, atArcLengths: stations)

        #expect(sections.count == stations.count)
        // Station index follows array order; arc length matches the request.
        for (i, sec) in sections.enumerated() {
            #expect(sec.stationIndex == i)
            #expect(abs(sec.arcLength - stations[i]) < 1e-9)
        }
    }

    @Test("Metrics on the circular tube are symmetric with sensible tree angles")
    func metricsOnTube() {
        let (curve, _, sections) = setup()
        let mid = sections[sections.count / 2]
        let m = SectionMetricsCalculator.metrics(for: mid, curve: curve)

        // Depth ≈ diameter (spine at apex, tube of radius 0.28).
        #expect(abs(m.depthBelowSpine - 0.56) < 0.03)
        // Symmetric section → small asymmetry error.
        #expect(m.symmetricErrorRMS < 0.005)
        // Tree angle at 5 cm on a 0.28 m circle ≈ atan(0.05/√(0.28²−0.05²)) ≈ 10.3°.
        #expect(abs(m.angleRightDegrees - 10.3) < 3)
        #expect(abs(m.angleLeftDegrees - 10.3) < 3)
        #expect(abs(m.angleLeftDegrees - m.angleRightDegrees) < 1.5)
        // Width at spine level is ~0 (spine sits at the section's apex).
        #expect(m.widthAtSpineLevel < 0.05)
        // Curvature is finite and non-negative.
        #expect(m.curvatureAlongSpine >= 0 && m.curvatureAlongSpine.isFinite)
        // A full closed section is reliable.
        #expect(m.isReliable)
    }

    /// A curve to satisfy the curvature term; its value is irrelevant here.
    private func anyCurve() -> SpineCurve {
        SpineCurveFitter.fit(SyntheticBackMesh.straightCylinder(segmentsAlong: 40, segmentsAround: 32))!.curve
    }

    private func makeSection(points2D: [SIMD2<Double>], closed: Bool) -> CrossSection {
        CrossSection(
            stationIndex: 0, arcLength: 0.3,
            origin: SIMD3<Double>(0.3, 0, 1.2), normal: SIMD3<Double>(1, 0, 0),
            uAxis: SIMD3<Double>(0, 1, 0), vAxis: SIMD3<Double>(0, 0, 1),
            points3D: [], points2D: points2D, isClosed: closed
        )
    }

    @Test("An open back arc spanning both sides is reliable (open ≠ unreliable)")
    func openArcSpanningBothSidesIsReliable() {
        // Inverted-U arc, apex ≈ spine, open — the normal saddle cross-section.
        let arc = makeSection(points2D: [
            SIMD2(-0.15, -0.09), SIMD2(-0.10, -0.04), SIMD2(-0.05, -0.01),
            SIMD2(0.0, 0.0), SIMD2(0.05, -0.01), SIMD2(0.10, -0.04), SIMD2(0.15, -0.09),
        ], closed: false)
        let m = SectionMetricsCalculator.metrics(for: arc, curve: anyCurve())

        #expect(m.isReliable)
        #expect(m.angleLeftDegrees.isFinite && m.angleRightDegrees.isFinite)
        #expect(m.depthBelowSpine > 0)
    }

    @Test("A section that doesn't reach ±5 cm on a side is unreliable")
    func partialSectionIsUnreliable() {
        // Right-side-only arc: no surface at u = −5 cm → left angle undefined.
        let arc = makeSection(points2D: [
            SIMD2(0.0, 0.0), SIMD2(0.03, -0.05), SIMD2(0.06, -0.12), SIMD2(0.10, -0.20),
        ], closed: false)
        let m = SectionMetricsCalculator.metrics(for: arc, curve: anyCurve())

        #expect(!m.isReliable)
        #expect(m.angleLeftDegrees.isNaN)
        // Depth and curvature stay valid.
        #expect(m.depthBelowSpine > 0)
        #expect(m.curvatureAlongSpine.isFinite)
    }
}
