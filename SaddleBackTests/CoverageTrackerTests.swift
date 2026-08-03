import Testing
import simd
@testable import SaddleBack

@Suite("Coverage tracker")
struct CoverageTrackerTests {

    private let faceCentroid = SIMD3<Float>(0, 0, 0)
    private let faceNormal = SIMD3<Float>(0, 0, 1)   // points toward a +Z camera

    private func face() -> [(centroid: SIMD3<Float>, normal: SIMD3<Float>)] {
        [(faceCentroid, faceNormal)]
    }

    @Test("A well-placed camera advances uncovered → partial → covered")
    func advancesThroughStates() {
        let tracker = CoverageTracker()
        let camera = SIMD3<Float>(0, 0, 0.5)   // 50 cm, head-on

        #expect(tracker.state(at: faceCentroid) == .uncovered)
        tracker.registerSnapshot(faces: face(), cameraPosition: camera)  // 1
        #expect(tracker.state(at: faceCentroid) == .uncovered)
        tracker.registerSnapshot(faces: face(), cameraPosition: camera)  // 2 → partial
        #expect(tracker.state(at: faceCentroid) == .partial)
        for _ in 0..<3 { tracker.registerSnapshot(faces: face(), cameraPosition: camera) } // 5 → covered
        #expect(tracker.state(at: faceCentroid) == .covered)
    }

    @Test("Views outside the distance band don't count")
    func distanceGating() {
        let tracker = CoverageTracker()
        for _ in 0..<10 {
            tracker.registerSnapshot(faces: face(), cameraPosition: SIMD3<Float>(0, 0, 0.1)) // too close
            tracker.registerSnapshot(faces: face(), cameraPosition: SIMD3<Float>(0, 0, 1.5)) // too far
        }
        #expect(tracker.state(at: faceCentroid) == .uncovered)
    }

    @Test("Grazing-angle views don't count")
    func angleGating() {
        let tracker = CoverageTracker()
        // Camera off to the side: ray nearly perpendicular to the face normal.
        for _ in 0..<10 {
            tracker.registerSnapshot(faces: face(), cameraPosition: SIMD3<Float>(0.9, 0, 0))
        }
        #expect(tracker.state(at: faceCentroid) == .uncovered)
    }

    @Test("Progress reports covered fraction")
    func progress() {
        let tracker = CoverageTracker()
        let camera = SIMD3<Float>(0, 0, 0.5)
        // Two faces 10 cm apart (different voxels); cover only one.
        let covered = SIMD3<Float>(0, 0, 0)
        let other = SIMD3<Float>(0.2, 0, 0)
        for _ in 0..<5 { tracker.registerSnapshot(faces: [(covered, faceNormal)], cameraPosition: camera) }
        tracker.registerSnapshot(faces: [(other, faceNormal)], cameraPosition: SIMD3<Float>(0.2, 0, 0.5))

        let p = tracker.progress
        #expect(p.total == 2)
        #expect(p.covered == 1)
        #expect(abs(p.fraction - 0.5) < 1e-9)
    }
}
