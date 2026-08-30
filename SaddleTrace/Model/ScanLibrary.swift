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
    func loadAnimals() async throws -> [AnimalRecord] {
        try ensureDirectory(root)
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var animals: [AnimalRecord] = []
        for dir in dirs {
            let info = dir.appendingPathComponent("info.json")
            await ensureDownloaded(info)
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
    func loadScans(for animalID: UUID) async throws -> [ScanRecord] {
        let scansDir = scansDirectory(animalID)
        guard FileManager.default.fileExists(atPath: scansDir.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: scansDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var scans: [ScanRecord] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("metadata.json")
            await ensureDownloaded(meta)
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
    func materialize(_ url: URL) async { await ensureDownloaded(url) }

    // MARK: - Share / import (Apple Archive)

    enum ImportError: Error { case invalidArchive }

    /// Manifest written at the archive root so an import can recognize + version it.
    private struct ArchiveManifest: Codable, Sendable { var version: Int; var kind: String; var created: Date }

    /// Archives a single scan (plus its animal's `info.json`) into a shareable
    /// `.saddletrace` file in a temp directory; returns its URL for the caller to
    /// share. The recipient reimports it with `importArchive(from:)`.
    func exportScan(animalID: UUID, scanID: UUID) async throws -> URL {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let fm = FileManager.default

        let animalStage = staging.appendingPathComponent("animals/\(animalID.uuidString)", isDirectory: true)
        try ensureDirectory(animalStage.appendingPathComponent("scans", isDirectory: true))

        let info = infoURL(animalID)
        await ensureDownloaded(info)
        try? fm.copyItem(at: info, to: animalStage.appendingPathComponent("info.json"))

        let src = scanDirectory(animalID, scanID)
        await downloadTree(src)
        try fm.copyItem(at: src, to: animalStage.appendingPathComponent("scans/\(scanID.uuidString)", isDirectory: true))

        try writeManifest(kind: "scan", to: staging)
        return try makeArchive(from: staging, named: await archiveName(animalID: animalID))
    }

    /// Archives the whole animal store into a shareable `.saddletrace` file; returns
    /// its URL. The recipient reimports it with `importArchive(from:)`.
    func exportAll() async throws -> URL {
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }

        try ensureDirectory(root)
        await downloadTree(root)
        try FileManager.default.copyItem(at: root, to: staging.appendingPathComponent("animals", isDirectory: true))

        try writeManifest(kind: "library", to: staging)
        return try makeArchive(from: staging, named: "SaddleTrace-AllScans-\(dateStamp())")
    }

    /// Imports an archive produced by `exportScan`/`exportAll`, merging its animals
    /// and scans into the store. New animals/scans are copied in; a scan whose id
    /// already exists is given a fresh id so nothing is overwritten. Returns the
    /// number of scans imported.
    @discardableResult
    func importArchive(from url: URL) throws -> Int {
        let extracted = try makeStaging()
        defer { try? FileManager.default.removeItem(at: extracted) }
        try ScanArchive.extract(url, to: extracted)

        let fm = FileManager.default
        let animalsDir = extracted.appendingPathComponent("animals", isDirectory: true)
        guard fm.fileExists(atPath: animalsDir.path) else { throw ImportError.invalidArchive }
        try ensureDirectory(root)

        var imported = 0
        let animalDirs = (try? fm.contentsOfDirectory(
            at: animalsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for aDir in animalDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: aDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let targetAnimal = root.appendingPathComponent(aDir.lastPathComponent, isDirectory: true)

            if !fm.fileExists(atPath: targetAnimal.path) {
                try fm.copyItem(at: aDir, to: targetAnimal)
                imported += scanCount(in: targetAnimal)
                continue
            }
            // Existing animal: merge scans, keeping the local info.json (name).
            let srcScans = aDir.appendingPathComponent("scans", isDirectory: true)
            let dstScans = targetAnimal.appendingPathComponent("scans", isDirectory: true)
            try ensureDirectory(dstScans)
            let scanDirs = (try? fm.contentsOfDirectory(
                at: srcScans, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for sDir in scanDirs {
                let existing = dstScans.appendingPathComponent(sDir.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: existing.path) {
                    let newID = UUID()
                    let target = dstScans.appendingPathComponent(newID.uuidString, isDirectory: true)
                    try fm.copyItem(at: sDir, to: target)
                    reidScan(at: target, newID: newID)
                } else {
                    try fm.copyItem(at: sDir, to: existing)
                }
                imported += 1
            }
        }
        return imported
    }

    // MARK: - Archive internals

    private func makeStaging() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeArchive(from staging: URL, named name: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).saddletrace")
        try? FileManager.default.removeItem(at: out)
        try ScanArchive.archive(contentsOf: staging, to: out)
        return out
    }

    private func writeManifest(kind: String, to staging: URL) throws {
        let manifest = ArchiveManifest(version: 1, kind: kind, created: .now)
        try Self.encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Rewrites a copied-in scan's `metadata.json` to carry a fresh id (used on id
    /// collision during import so the existing scan isn't clobbered).
    private func reidScan(at dir: URL, newID: UUID) {
        let meta = dir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: meta),
              let s = try? Self.decoder.decode(ScanRecord.self, from: data) else { return }
        let updated = ScanRecord(
            id: newID, timestamp: s.timestamp, captureMode: s.captureMode, detail: s.detail,
            status: s.status, deviceModel: s.deviceModel, osVersion: s.osVersion,
            stationSpacingMeters: s.stationSpacingMeters, processingSeconds: s.processingSeconds)
        try? Self.encoder.encode(updated).write(to: meta, options: .atomic)
    }

    private func scanCount(in animalDir: URL) -> Int {
        let scans = animalDir.appendingPathComponent("scans", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: scans, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.count ?? 0
    }

    /// A shareable file name from the animal's name + a timestamp.
    private func archiveName(animalID: UUID) async -> String {
        let info = infoURL(animalID)
        await ensureDownloaded(info)
        var base = "Scan"
        if let data = try? Data(contentsOf: info),
           let animal = try? Self.decoder.decode(AnimalRecord.self, from: data) {
            base = animal.name
        }
        let safe = base.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        return "\(safe.isEmpty ? "Scan" : safe)-\(dateStamp())"
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: .now)
    }

    /// Best-effort recursive iCloud download so evicted files are present before
    /// archiving. No-op for local (non-iCloud) stores.
    ///
    /// Requests every download FIRST and then waits once. Waiting per file in
    /// turn meant a large evicted store took (5 s × file count) to archive.
    private func downloadTree(_ url: URL) async {
        var requested: [URL] = []
        for candidate in [url] + descendants(of: url) where needsDownload(candidate) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: candidate)
            requested.append(candidate)
        }
        await waitUntilDownloaded(requested, timeout: Self.treeDownloadTimeout)
    }

    private nonisolated func descendants(of url: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
    }

    // MARK: - Internals

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static let fileDownloadTimeout: Duration = .seconds(5)
    private static let treeDownloadTimeout: Duration = .seconds(60)

    /// Whether `url` is an iCloud item that is currently evicted. False for
    /// non-iCloud items, which never need downloading.
    private nonisolated func needsDownload(_ url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// If `url` is an evicted iCloud item, request it and wait briefly
    /// (best-effort; needs a network connection). No-op otherwise.
    private func ensureDownloaded(_ url: URL) async {
        guard needsDownload(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        await waitUntilDownloaded([url], timeout: Self.fileDownloadTimeout)
    }

    /// Polls already-requested downloads until all are local or `timeout` passes.
    ///
    /// Suspends rather than blocking: this runs on the actor's executor, where the
    /// previous `Thread.sleep` tied up a cooperative thread for the whole wait.
    private func waitUntilDownloaded(_ urls: [URL], timeout: Duration) async {
        guard !urls.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var pending = urls
        while ContinuousClock.now < deadline {
            pending = pending.filter { needsDownload($0) }
            if pending.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
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
