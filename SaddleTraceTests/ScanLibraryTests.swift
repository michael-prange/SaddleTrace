import Testing
import Foundation
@testable import SaddleBack

@Suite("ScanLibrary persistence")
struct ScanLibraryTests {

    /// A library rooted in a unique temp directory, plus a cleanup handle.
    private func makeLibrary() -> (ScanLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saddleback_tests_\(UUID().uuidString)", isDirectory: true)
        return (ScanLibrary(root: root), root)
    }

    @Test("Animals round-trip through info.json")
    func animalRoundTrip() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = AnimalRecord(name: "Comanche", species: .horse,
                                  dateOfBirth: Date(timeIntervalSince1970: 0), notes: "bay gelding")
        try await lib.save(animal)

        let loaded = try await lib.loadAnimals()
        #expect(loaded.count == 1)
        #expect(loaded.first == animal)
        #expect(FileManager.default.fileExists(atPath: lib.infoURL(animal.id).path))
    }

    @Test("Animals are returned sorted by name")
    func animalsSorted() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        try await lib.save(AnimalRecord(name: "Zephyr", species: .mule))
        try await lib.save(AnimalRecord(name: "Apollo", species: .llama))
        let names = try await lib.loadAnimals().map(\.name)
        #expect(names == ["Apollo", "Zephyr"])
    }

    @Test("Scans persist with their standard subdirectories, newest first")
    func scanRoundTrip() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = AnimalRecord(name: "Comanche", species: .horse)
        try await lib.save(animal)

        let older = ScanRecord(timestamp: Date(timeIntervalSince1970: 1000))
        let newer = ScanRecord(timestamp: Date(timeIntervalSince1970: 2000))
        try await lib.save(older, for: animal.id)
        try await lib.save(newer, for: animal.id)

        let scans = try await lib.loadScans(for: animal.id)
        #expect(scans.map(\.id) == [newer.id, older.id])   // newest first

        // Standard subdirectories exist.
        for dir in [lib.framesDirectory(animal.id, newer.id),
                    lib.sectionsDirectory(animal.id, newer.id),
                    lib.exportsDirectory(animal.id, newer.id)] {
            #expect(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @Test("Deleting raw frames keeps the mesh metadata (Design §10)")
    func deleteRawFramesKeepsMetadata() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = AnimalRecord(name: "Comanche", species: .horse)
        let scan = ScanRecord()
        try await lib.save(animal)
        try await lib.save(scan, for: animal.id)

        // Drop a fake frame in the frames directory.
        let frame = lib.framesDirectory(animal.id, scan.id).appendingPathComponent("0000.HEIC")
        try Data([0x1, 0x2]).write(to: frame)

        try await lib.deleteRawFrames(scan.id, for: animal.id)

        #expect(!FileManager.default.fileExists(atPath: lib.framesDirectory(animal.id, scan.id).path))
        #expect(FileManager.default.fileExists(atPath: lib.metadataURL(animal.id, scan.id).path))
        // The scan record itself still loads.
        #expect(try await lib.loadScans(for: animal.id).count == 1)
    }

    @Test("Deleting an animal removes its directory and scans")
    func deleteAnimal() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let animal = AnimalRecord(name: "Comanche", species: .horse)
        try await lib.save(animal)
        try await lib.save(ScanRecord(), for: animal.id)

        try await lib.deleteAnimal(animal.id)
        #expect(!FileManager.default.fileExists(atPath: lib.animalDirectory(animal.id).path))
        #expect(try await lib.loadAnimals().isEmpty)
    }

    @Test("Loading from an empty store yields no animals")
    func emptyStore() async throws {
        let (lib, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await lib.loadAnimals().isEmpty)
    }
}
