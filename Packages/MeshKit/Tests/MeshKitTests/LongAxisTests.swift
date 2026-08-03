import Testing
import simd
import Foundation
@testable import MeshKit

@Suite("Long-axis PCA & normalization")
struct LongAxisTests {

    /// Rotation about the vertical (Z) axis by `degrees`, plus an optional XY shift.
    private func zRotation(degrees: Float, shift: SIMD2<Float> = .zero) -> simd_float4x4 {
        let a = degrees * .pi / 180
        let ca = cos(a), sa = sin(a)
        return simd_float4x4(
            SIMD4<Float>(ca, sa, 0, 0),
            SIMD4<Float>(-sa, ca, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(shift.x, shift.y, 0, 1)
        )
    }

    @Test("PCA recovers the long axis of the raw synthetic mesh (aligned to +X)")
    func recoversAxisOfAlignedMesh() {
        let (mesh, _) = SyntheticBackMesh.make()
        let axis = LongAxisPCA.longAxis(of: mesh)
        // Should be parallel to X; sign is canonicalized to +X.
        #expect(abs(axis.x) > 0.999)
        #expect(abs(axis.y) < 1e-2)
    }

    @Test("PCA recovers the long axis after a known Z-rotation")
    func recoversAxisAfterRotation() {
        let (mesh, _) = SyntheticBackMesh.make()
        for deg in [15, 35, 60, 100, 160] as [Float] {
            let rotated = mesh.transformed(by: zRotation(degrees: deg, shift: SIMD2<Float>(2, -1)))
            let axis = LongAxisPCA.longAxis(of: rotated)

            let a = deg * .pi / 180
            let expected = SIMD3<Float>(cos(a), sin(a), 0)
            // Compare as an undirected line: |dot| ≈ 1.
            #expect(abs(simd_dot(axis, expected)) > 0.999, "deg=\(deg)")
        }
    }

    @Test("Normalizer brings the long axis back onto +X")
    func normalizerAlignsToX() {
        let (mesh, truth) = SyntheticBackMesh.make()
        let rotated = mesh.transformed(by: zRotation(degrees: 47, shift: SIMD2<Float>(-3, 5)))

        let result = LongAxisNormalizer.normalized(rotated)
        let axis = LongAxisPCA.longAxis(of: result.mesh)
        #expect(abs(axis.x) > 0.999)
        #expect(abs(axis.y) < 1e-2)

        // The X-extent of the normalized mesh should match the back length,
        // since the long axis is now aligned with X.
        let extentX = result.mesh.bounds.max.x - result.mesh.bounds.min.x
        #expect(abs(extentX - truth.tailX) < 0.02)
    }

    @Test("Top-region filter excludes vertices below the height threshold")
    func topRegionFilter() {
        // A long axis along X for the top band, but a spurious cluster of low
        // "leg" points spread along Y that would rotate the axis if not filtered.
        var positions: [SIMD3<Float>] = []
        for i in 0...40 {
            positions.append(SIMD3<Float>(Float(i) * 0.05, 0, 1.2)) // top band along X
        }
        for j in -20...20 {
            positions.append(SIMD3<Float>(0, Float(j) * 0.05, 0.1)) // low band along Y
        }
        let mesh = TriangleMesh(positions: positions, indices: [0, 1, 2])
        let axis = LongAxisPCA.longAxis(of: mesh, topRegionMinHeight: 0.8)
        #expect(abs(axis.x) > 0.999) // dominated by the top band, not the legs
    }
}
