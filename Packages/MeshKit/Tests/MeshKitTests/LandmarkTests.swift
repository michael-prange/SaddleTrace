import Testing
import simd
import Foundation
@testable import MeshKit

@Suite("Landmark detection")
struct LandmarkTests {

    private func zRotation(_ degrees: Float, shift: SIMD2<Float> = .zero) -> simd_float4x4 {
        let a = degrees * .pi / 180, ca = cos(a), sa = sin(a)
        return simd_float4x4(
            SIMD4<Float>(ca, sa, 0, 0),
            SIMD4<Float>(-sa, ca, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(shift.x, shift.y, 0, 1)
        )
    }

    @Test("Locates withers, croup and loin on the synthetic back")
    func locatesLandmarks() {
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: 220, segmentsAround: 48)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        let marks = LandmarkDetector.detect(on: curve)

        #expect(abs(marks.withersX - Double(truth.withersX)) < 0.03)
        #expect(abs(marks.croupX - Double(truth.croupX)) < 0.05)
        #expect(abs(marks.loinX - Double(truth.loinX)) < 0.05)

        // Height ordering: withers highest, loin lowest of the three.
        #expect(marks.withersPoint.z > marks.croupPoint.z)
        #expect(marks.croupPoint.z > marks.loinPoint.z)

        // Withers is cranial of croup here (croup at larger X → caudal is +X).
        #expect(marks.caudalSign == 1)
        #expect(abs(marks.tailBaseX - curve.xMax) < 1e-6)
    }

    @Test("Front cutoff is the configured distance cranial of the withers")
    func frontCutoff() {
        let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: 220, segmentsAround: 48)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        let marks = LandmarkDetector.detect(on: curve)

        // Caudal is +X, so cranial reduces arc length by 15 cm.
        #expect(abs((marks.withersArcLength - marks.frontCutoffArcLength) - 0.15) < 1e-3)
        // ROI spans from front cutoff to the tail (caudal) end.
        #expect(marks.roiArcLengthRange.lowerBound == marks.frontCutoffArcLength)
        #expect(abs(marks.roiArcLengthRange.upperBound - curve.totalArcLength) < 1e-6)
    }

    @Test("Head/tail sign flips when the mesh is reversed")
    func resolvesReversedOrientation() {
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: 220, segmentsAround: 48)
        // Rotate 180° about Z: reverses the long axis (x → −x).
        let reversed = LongAxisNormalizer.normalized(mesh.transformed(by: zRotation(180))).mesh
        let curve = SpineCurveFitter.fit(reversed)!.curve
        let marks = LandmarkDetector.detect(on: curve)

        // The withers are still the global maximum and cranial of the croup,
        // but now the croup sits at smaller X, so caudal points to −X.
        #expect(marks.caudalSign == -1)
        #expect(marks.withersPoint.z > marks.croupPoint.z)
        // Withers–croup separation should match the ground-truth spacing.
        let truthGap = Double(truth.croupX - truth.withersX)
        #expect(abs(abs(marks.croupX - marks.withersX) - truthGap) < 0.06)
        // Cranial is now +X, so the front cutoff has a larger arc length.
        #expect(marks.frontCutoffArcLength > marks.withersArcLength)
    }
}
