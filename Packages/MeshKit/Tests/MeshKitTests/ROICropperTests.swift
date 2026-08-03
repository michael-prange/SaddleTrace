import Testing
import simd
import Foundation
@testable import MeshKit

@Suite("ROI cropping")
struct ROICropperTests {

    private func fittedSynthetic() -> (TriangleMesh, SpineCurve, Landmarks) {
        let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: 200, segmentsAround: 48)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        let marks = LandmarkDetector.detect(on: curve)
        return (mesh, curve, marks)
    }

    @Test("Trims cranial of the front cutoff, keeps back through the tail")
    func trimsCranialEnd() {
        let (mesh, curve, marks) = fittedSynthetic()
        let result = ROICropper.crop(mesh, curve: curve, roiArcLength: marks.roiArcLengthRange)
        let cropped = result.mesh

        #expect(cropped.triangleCount > 0)
        // Nothing survives cranial of the front cutoff (~withers − 15 cm).
        let frontX = curve.x(atArcLength: marks.frontCutoffArcLength)
        #expect(cropped.bounds.min.x >= Float(frontX) - 0.03)
        // The full cranial region was actually removed (original started at 0).
        #expect(cropped.bounds.min.x > mesh.bounds.min.x + 0.1)
        // The caudal end is retained.
        #expect(abs(cropped.bounds.max.x - mesh.bounds.max.x) < 0.05)
    }

    @Test("Lateral limit keeps only the crest band")
    func lateralLimitCropsFlanks() {
        let (mesh, curve, marks) = fittedSynthetic()
        var cfg = ROICropper.Configuration()
        cfg.lateralLimit = 0.12   // tighter than the 0.28 m tube radius
        let cropped = ROICropper.crop(mesh, curve: curve,
                                      roiArcLength: marks.roiArcLengthRange,
                                      configuration: cfg).mesh

        #expect(cropped.triangleCount > 0)
        // The lower flanks (far from the crest in 3D) are gone, so the mesh
        // floor rises well above the full tube's underside.
        #expect(cropped.bounds.min.z > mesh.bounds.min.z + 0.1)
        // Every kept vertex is within the lateral limit of the spine.
        for v in cropped.positions {
            let (_, d) = curve.closestPoint(to: SIMD3<Double>(v))
            #expect(d <= 0.12 + 1e-3)
        }
    }

    @Test("Cropping is idempotent-ish: re-cropping the result changes little")
    func stableUnderRecrop() {
        let (mesh, curve, marks) = fittedSynthetic()
        let once = ROICropper.crop(mesh, curve: curve, roiArcLength: marks.roiArcLengthRange).mesh
        let twice = ROICropper.crop(once, curve: curve, roiArcLength: marks.roiArcLengthRange).mesh
        #expect(twice.triangleCount == once.triangleCount)
    }
}
