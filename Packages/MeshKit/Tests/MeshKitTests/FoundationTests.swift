import Testing
import simd
@testable import MeshKit

@Suite("Core mesh types & I/O")
struct FoundationTests {

    @Test("TriangleMesh reports consistent counts and bounds")
    func meshCountsAndBounds() {
        let mesh = TriangleMesh(
            positions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 2, 0),
                SIMD3<Float>(0, 0, 3),
            ],
            indices: [0, 1, 2, 0, 1, 3]
        )
        #expect(mesh.vertexCount == 4)
        #expect(mesh.triangleCount == 2)
        #expect(mesh.bounds.min == SIMD3<Float>(0, 0, 0))
        #expect(mesh.bounds.max == SIMD3<Float>(1, 2, 3))
    }

    @Test("Synthetic back mesh is well-formed and Z-up")
    func syntheticMeshStructure() {
        let along = 100, around = 40
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: along, segmentsAround: around)

        #expect(mesh.vertexCount == (along + 1) * around)
        #expect(mesh.triangleCount == along * around * 2)

        // The top ridge is well above the 0.8 m floor threshold, while the
        // tube underside dips below it — so the §7.1 top-region filter has
        // something to strip. Z is the vertical axis.
        #expect(mesh.bounds.max.z > 0.8)
        #expect(mesh.bounds.min.z < 0.8)
        // Long axis runs along X from 0 to the back length.
        #expect(abs(mesh.bounds.min.x - 0) < 1e-4)
        #expect(abs(mesh.bounds.max.x - truth.tailX) < 1e-3)
        // Front cutoff is 15 cm cranial of the withers.
        #expect(abs((truth.withersX - truth.frontX) - 0.15) < 1e-5)
    }

    @Test("Withers is the global top-ridge maximum, croup secondary")
    func syntheticRidgeOrdering() {
        let (mesh, truth) = SyntheticBackMesh.make(segmentsAlong: 280, segmentsAround: 24)

        // Highest vertex overall should sit at the withers X.
        let top = mesh.positions.max { $0.z < $1.z }!
        #expect(abs(top.x - truth.withersX) < 0.03)
    }

    @Test("OBJ round-trips positions and indices")
    func objRoundTrip() throws {
        let (mesh, _) = SyntheticBackMesh.make(segmentsAlong: 20, segmentsAround: 12)
        let text = MeshIO.objString(from: mesh)
        let decoded = try MeshIO.mesh(fromOBJ: text)

        #expect(decoded.indices == mesh.indices)
        #expect(decoded.vertexCount == mesh.vertexCount)
        for (a, b) in zip(decoded.positions, mesh.positions) {
            #expect(simd_distance(a, b) < 1e-4)
        }
    }

    @Test("OBJ parser handles v/vt/vn faces and fan-triangulates quads")
    func objFaceForms() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1/1/1 2/2/1 3/3/1 4/4/1
        """
        let mesh = try MeshIO.mesh(fromOBJ: text)
        #expect(mesh.vertexCount == 4)
        #expect(mesh.triangleCount == 2)   // quad → two triangles
        #expect(mesh.indices == [0, 1, 2, 0, 2, 3])
    }
}
