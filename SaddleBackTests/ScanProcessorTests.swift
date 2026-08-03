import Testing
import Foundation
import simd
@testable import SaddleBack

@MainActor
@Suite("Scan processing end-to-end")
struct ScanProcessorTests {

    private func makeModel() -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saddleback_proc_\(UUID().uuidString)", isDirectory: true)
        return (AppModel(library: ScanLibrary(root: root)), root)
    }

    @Test("Processing a scan produces sections, metrics and export files")
    func processesEndToEnd() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = try #require(await model.addAnimal(name: "Comanche", species: .horse,
                                                        dateOfBirth: nil, notes: ""))
        let scan = try #require(await model.startNewScan(for: animal.id))
        // A just-captured scan awaits reconstruction (not still "capturing").
        #expect(scan.status == .awaitingReconstruction)

        let maybe = await model.processScan(scan, for: animal.id)
        let result = try #require(maybe, "processScan failed: \(model.errorMessage ?? "unknown")")

        // Geometry outputs.
        #expect(result.sectionCount > 5)
        #expect(result.metrics.count == result.sectionCount)
        #expect(result.sections.count == result.sectionCount)
        #expect(result.roiTriangleCount > 0)
        #expect(result.spine.totalArcLength > 1.0)   // ~1.4 m synthetic back

        // Visualization data is populated and finite.
        #expect(!result.rocker.isEmpty)
        #expect(result.rocker.allSatisfy { $0.x.isFinite && $0.y.isFinite })

        // Export files landed on disk.
        let fm = FileManager.default
        for url in [result.exports.roiOBJ, result.exports.sectionsDXF,
                    result.exports.sectionsCSV, result.exports.metricsCSV,
                    result.exports.spineJSON] {
            #expect(fm.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        // ROI USDZ is best-effort; if reported, it must exist.
        if let usdz = result.exports.roiUSDZ {
            #expect(fm.fileExists(atPath: usdz.path))
        }
        // STL of the back mesh is always written.
        #expect(fm.fileExists(atPath: result.exports.roiSTL.path))

        // The scan is marked complete, records a processing time, and reloads so.
        let reloaded = await model.scans(for: animal.id)
        #expect(reloaded.first?.status == .complete)
        #expect((reloaded.first?.processingSeconds ?? 0) > 0)
        #expect(reloaded.first?.processingSummary != nil)
    }

    @Test("spine.json round-trips as a SpineSummary")
    func spineJSONDecodes() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = try #require(await model.addAnimal(name: "Zephyr", species: .mule,
                                                        dateOfBirth: nil, notes: ""))
        let scan = try #require(await model.startNewScan(for: animal.id))
        let result = try #require(await model.processScan(scan, for: animal.id))

        let data = try Data(contentsOf: result.exports.spineJSON)
        let summary = try JSONDecoder().decode(SpineSummary.self, from: data)
        #expect(summary.totalArcLength == result.spine.totalArcLength)
        #expect(summary.roiUpperArcLength > summary.roiLowerArcLength)
    }
}
