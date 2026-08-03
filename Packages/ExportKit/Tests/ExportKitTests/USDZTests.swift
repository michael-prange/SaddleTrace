import Testing
import Foundation
import ModelIO
import MeshKit
@testable import ExportKit

@Suite("USDZ export")
struct USDZTests {

    // Model I/O's USDZ exporter plugin is only registered inside an app/Xcode
    // context, not the headless SwiftPM CLI — so this runs on-device/in-Xcode
    // and is skipped (not failed) when export is unavailable.
    @Test("Writes a non-empty USDZ file that re-imports with geometry",
          .enabled(if: MDLAsset.canExportFileExtension("usdz")))
    func writesUSDZ() throws {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 20, segmentsAround: 24)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saddleback_test_\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: url) }

        try USDZWriter.write(mesh, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 0)

        // Re-import and confirm at least one mesh with vertices came back.
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        #expect(!meshes.isEmpty)
        #expect((meshes.first?.vertexCount ?? 0) > 0)
    }

    @Test("Rejects an empty mesh")
    func rejectsEmpty() {
        let empty = TriangleMesh(positions: [], indices: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty.usdz")
        #expect(throws: USDZWriter.ExportError.emptyMesh) {
            try USDZWriter.write(empty, to: url)
        }
    }
}
