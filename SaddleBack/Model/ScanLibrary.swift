import Foundation

/// File-based persistence for animals and their scans, following the on-disk
/// layout in Design §10. Isolated to its own actor so all disk I/O stays off the
/// main actor; `AppModel` awaits it. URL helpers are `nonisolated` (pure path
/// arithmetic) so views can address artifacts synchronously.
actor ScanLibrary {

    /// Root of the animal store (`…/animals`).
    nonisolated let root: URL

    /// Creates a library rooted at `root`. Defaults to `Documents/animals`.
    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.root = docs.appendingPathComponent("animals", isDirectory: true)
        }
    }

    // MARK: - Path helpers (nonisolated)

    nonisolated func animalDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    nonisolated func infoURL(_ animalID: UUID) -> URL {
        animalDirectory(animalID).appendingPathComponent("info.json")
    }
    nonisolated func scansDirectory(_ animalID: UUID) -> URL {
        animalDirectory(animalID).appendingPathComponent("scans", isDirectory: true)
    }
    nonisolated func scanDirectory(_ animalID: UUID, _ scanID: UUID) -> URL {
        scansDirectory(animalID).appendingPathComponent(scanID.uuidString, isDirectory: true)
    }
    nonisolated func metadataURL(_ animalID: UUID, _ scanID: UUID) -> URL {
        scanDirectory(animalID, scanID).appendingPathComponent("metadata.json")
    }
    nonisolated func framesDirectory(_ animalID: UUID, _ scanID: UUID) -> URL {
        scanDirectory(animalID, scanID).appendingPathComponent("frames", isDirectory: true)
    }
    nonisolated func sectionsDirectory(_ animalID: UUID, _ scanID: UUID) -> URL {
        scanDirectory(animalID, scanID).appendingPathComponent("sections", isDirectory: true)
    }
    nonisolated func exportsDirectory(_ animalID: UUID, _ scanID: UUID) -> URL {
        scanDirectory(animalID, scanID).appendingPathComponent("exports", isDirectory: true)
    }
    /// Well-known artifact files within a scan directory (Design §10).
    nonisolated func artifactURL(_ animalID: UUID, _ scanID: UUID, _ artifact: Artifact) -> URL {
        scanDirectory(animalID, scanID).appendingPathComponent(artifact.rawValue)
    }

    nonisolated enum Artifact: String, Sendable {
        case coarsePLY = "coarse.ply"
        case modelUSDZ = "model.usdz"
        case roiOBJ = "roi.obj"
        case spineJSON = "spine.json"
    }

    // MARK: - Animals

    /// Loads all animals, sorted by name. Malformed records are skipped.
    func loadAnimals() throws -> [AnimalRecord] {
        try ensureDirectory(root)
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var animals: [AnimalRecord] = []
        for dir in dirs {
            let info = dir.appendingPathComponent("info.json")
            ensureDownloaded(info)
            guard let data = try? Data(contentsOf: info),
                  let record = try? Self.decoder.decode(AnimalRecord.self, from: data)
            else { continue }
            animals.append(record)
        }
        return animals.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates or updates an animal, writing `info.json` and ensuring its
    /// `scans/` directory exists.
    func save(_ animal: AnimalRecord) throws {
        try ensureDirectory(animalDirectory(animal.id))
        try ensureDirectory(scansDirectory(animal.id))
        try Self.encoder.encode(animal).write(to: infoURL(animal.id), options: .atomic)
    }

    /// Deletes an animal and all of its scans.
    func deleteAnimal(_ id: UUID) throws {
        let dir = animalDirectory(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Scans

    /// Loads an animal's scans, newest first.
    func loadScans(for animalID: UUID) throws -> [ScanRecord] {
        let scansDir = scansDirectory(animalID)
        guard FileManager.default.fileExists(atPath: scansDir.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: scansDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var scans: [ScanRecord] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("metadata.json")
            ensureDownloaded(meta)
            guard let data = try? Data(contentsOf: meta),
                  let record = try? Self.decoder.decode(ScanRecord.self, from: data)
            else { continue }
            scans.append(record)
        }
        return scans.sorted { $0.timestamp > $1.timestamp }
    }

    /// Creates or updates a scan, writing `metadata.json` and ensuring its
    /// standard subdirectories exist.
    func save(_ scan: ScanRecord, for animalID: UUID) throws {
        try ensureDirectory(scanDirectory(animalID, scan.id))
        try ensureDirectory(framesDirectory(animalID, scan.id))
        try ensureDirectory(sectionsDirectory(animalID, scan.id))
        try ensureDirectory(exportsDirectory(animalID, scan.id))
        try Self.encoder.encode(scan).write(to: metadataURL(animalID, scan.id), options: .atomic)
    }

    func deleteScan(_ scanID: UUID, for animalID: UUID) throws {
        let dir = scanDirectory(animalID, scanID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Moves captured frames from a temporary directory into the scan's
    /// `frames/` directory. Used to promote a capture into a saved scan.
    func importFrames(from tempDirectory: URL, animalID: UUID, scanID: UUID) throws {
        let destination = framesDirectory(animalID, scanID)
        try ensureDirectory(destination)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: item, to: target)
        }
        try? fm.removeItem(at: tempDirectory)
    }

    /// Purges the raw frame data for a scan while keeping meshes and exports
    /// (Design §10 "Delete raw frames, keep mesh").
    func deleteRawFrames(_ scanID: UUID, for animalID: UUID) throws {
        let dir = framesDirectory(animalID, scanID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Materializes an iCloud-evicted artifact on demand (best-effort). Public
    /// entry point for readers like the result loader.
    func materialize(_ url: URL) { ensureDownloaded(url) }

    // MARK: - Internals

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// If `url` is an iCloud item that's been evicted locally, request its
    /// download and briefly wait for small files to materialize (best-effort;
    /// requires a network connection). No-op for non-iCloud or already-local files.
    private func ensureDownloaded(_ url: URL) {
        let fm = FileManager.default
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus, status != .current else { return }
        try? fm.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<50 {
            if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus) == .current { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
