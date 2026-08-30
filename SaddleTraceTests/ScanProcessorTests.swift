import Testing
import Foundation
@testable import SaddleBack

/// App-level scan-record plumbing. The geometry pipeline itself is validated in
/// MeshKit's own tests; the synthetic "demo" processing path has been removed now
/// that real single-shot LiDAR capture drives the pipeline (device-only).
@MainActor
@Suite("Scan record plumbing")
struct ScanProcessorTests {

    private func makeModel() -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saddleback_proc_\(UUID().uuidString)", isDirectory: true)
        return (AppModel(library: ScanLibrary(root: root)), root)
    }

    @Test("A new scan is recorded awaiting reconstruction and reloads")
    func newScanRecorded() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = try #require(await model.addAnimal(name: "Comanche", species: .horse,
                                                        dateOfBirth: nil, notes: ""))
        let scan = try #require(await model.startNewScan(for: animal.id))
        #expect(scan.status == .awaitingReconstruction)

        let reloaded = await model.scans(for: animal.id)
        #expect(reloaded.contains { $0.id == scan.id })
    }

    @Test("Loading a result for a scan with no captured mesh returns nil")
    func loadResultWithoutMeshIsNil() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = try #require(await model.addAnimal(name: "Zephyr", species: .mule,
                                                        dateOfBirth: nil, notes: ""))
        let scan = try #require(await model.startNewScan(for: animal.id))
        let result = await model.loadResult(for: scan, animalID: animal.id)
        #expect(result == nil)
    }
}
