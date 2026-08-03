import Foundation
import Observation
import simd
import MeshKit
import ExportKit

/// App-wide observable state and the entry point to persistence. Owns the list
/// of animals and mediates all `ScanLibrary` access (Design §14 AppModel).
@MainActor
@Observable
final class AppModel {
    private(set) var animals: [AnimalRecord] = []
    var errorMessage: String?
    /// Reconstruction progress (0–1) while a scan is being reconstructed.
    var reconstructionProgress: Double?

    /// Whether this device can reconstruct scans (PhotogrammetrySession).
    var canReconstruct: Bool { ReconstructionDriver.isSupported }

    /// USD (Y-up) → MeshKit (Z-up): rotate +90° about X, (x,y,z) → (x,−z,y).
    private static let yUpToZUp = simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(0, 0, 0, 1))

    private let library: ScanLibrary
    private let processor: ScanProcessor
    /// Whether scans are stored in iCloud Drive (auto-offloaded) vs on-device.
    let isUsingICloud: Bool

    init(library: ScanLibrary = ScanLibrary(), isUsingICloud: Bool = false) {
        self.library = library
        self.processor = ScanProcessor(library: library)
        self.isUsingICloud = isUsingICloud
    }

    /// Builds the app model, resolving the storage location (iCloud Drive vs
    /// local) off the main thread.
    static func make() async -> AppModel {
        let resolved = await Task.detached(priority: .userInitiated) { StorageRoot.resolve() }.value
        return AppModel(library: ScanLibrary(root: resolved.url), isUsingICloud: resolved.isICloud)
    }

    // MARK: - Animals

    func loadAnimals() async {
        do { animals = try await library.loadAnimals() }
        catch { errorMessage = "Couldn't load animals: \(error.localizedDescription)" }
    }

    @discardableResult
    func addAnimal(name: String, species: Species, dateOfBirth: Date?, notes: String) async -> AnimalRecord? {
        let record = AnimalRecord(name: name, species: species, dateOfBirth: dateOfBirth, notes: notes)
        do {
            try await library.save(record)
            await loadAnimals()
            return record
        } catch {
            errorMessage = "Couldn't save animal: \(error.localizedDescription)"
            return nil
        }
    }

    func update(_ animal: AnimalRecord) async {
        do { try await library.save(animal); await loadAnimals() }
        catch { errorMessage = "Couldn't update animal: \(error.localizedDescription)" }
    }

    func deleteAnimal(_ id: UUID) async {
        do { try await library.deleteAnimal(id); await loadAnimals() }
        catch { errorMessage = "Couldn't delete animal: \(error.localizedDescription)" }
    }

    // MARK: - Scans

    func scans(for animalID: UUID) async -> [ScanRecord] {
        do { return try await library.loadScans(for: animalID) }
        catch { errorMessage = "Couldn't load scans: \(error.localizedDescription)"; return [] }
    }

    /// Creates a new scan record (capture pipeline lands with CaptureKit).
    @discardableResult
    func startNewScan(for animalID: UUID, mode: CaptureMode = .lidar,
                      detail: ReconstructionDetail = .reduced,
                      stationSpacingMeters: Double = 0.1016) async -> ScanRecord? {
        // Capture has ended by the time we record the scan; it awaits
        // reconstruction rather than still "capturing".
        let scan = ScanRecord(
            captureMode: mode, detail: detail, status: .awaitingReconstruction,
            deviceModel: DeviceInfo.modelIdentifier, osVersion: DeviceInfo.osVersion,
            stationSpacingMeters: stationSpacingMeters
        )
        do {
            try await library.save(scan, for: animalID)
            return scan
        } catch {
            errorMessage = "Couldn't start scan: \(error.localizedDescription)"
            return nil
        }
    }

    /// Finalizes a capture: creates the scan record and promotes its captured
    /// frames (from a temp directory) into it. `tempFramesDirectory` is nil for
    /// the demo path (no real frames).
    @discardableResult
    func finishCapture(for animalID: UUID, mode: CaptureMode, detail: ReconstructionDetail,
                       stationSpacingMeters: Double, tempFramesDirectory: URL?) async -> ScanRecord? {
        guard let scan = await startNewScan(for: animalID, mode: mode, detail: detail,
                                            stationSpacingMeters: stationSpacingMeters) else { return nil }
        if let temp = tempFramesDirectory {
            do { try await library.importFrames(from: temp, animalID: animalID, scanID: scan.id) }
            catch { errorMessage = "Couldn't save frames: \(error.localizedDescription)" }
        }
        return scan
    }

    func delete(scan scanID: UUID, from animalID: UUID) async {
        do { try await library.deleteScan(scanID, for: animalID) }
        catch { errorMessage = "Couldn't delete scan: \(error.localizedDescription)" }
    }

    /// Generates the single-page cross-section PDF for a processed scan and
    /// returns its URL. Uses the current unit + page-size settings.
    private func generateReportPDF(_ result: ProcessedScan, animalID: UUID, scanID: UUID) -> URL? {
        let defaults = UserDefaults.standard
        let imperial = defaults.string(forKey: "measurementSystem") == MeasurementSystem.imperial.rawValue
        let pageSize = PDFPageSize(rawValue: defaults.string(forKey: "pdfPageSize") ?? "") ?? .letter
        let name = animals.first { $0.id == animalID }?.name ?? "Animal"
        let date = Date.now.formatted(date: .abbreviated, time: .shortened)
        let url = library.exportsDirectory(animalID, scanID).appendingPathComponent("report.pdf")
        do {
            try PDFReportWriter.write(animalName: name, dateText: date,
                                      sections: result.sections, rocker: result.rocker,
                                      imperial: imperial, pageSize: pageSize, to: url)
            return url
        } catch {
            errorMessage = "Couldn't write PDF: \(error.localizedDescription)"
            return nil
        }
    }

    /// Whether a scan has captured frames available to reconstruct.
    nonisolated func hasCapturedFrames(animalID: UUID, scanID: UUID) -> Bool {
        let dir = library.framesDirectory(animalID, scanID)
        let heics = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "heic" } ?? []
        return !heics.isEmpty
    }

    /// Tail of the serialized reconstruction queue, so back-to-back captures
    /// reconstruct one at a time (a single `PhotogrammetrySession` and one shared
    /// progress value at once).
    private var reconstructionTask: Task<Void, Never>?

    /// Automatically reconstructs a freshly captured scan when the device supports
    /// photogrammetry and frames were actually saved. Chains behind any in-flight
    /// reconstruction and returns once THIS scan has finished (or was skipped).
    func autoReconstruct(_ scan: ScanRecord, for animalID: UUID) async {
        guard ReconstructionDriver.isSupported,
              hasCapturedFrames(animalID: animalID, scanID: scan.id) else { return }
        let previous = reconstructionTask
        let task = Task { @MainActor in
            await previous?.value
            _ = await self.reconstructScan(scan, for: animalID)
        }
        reconstructionTask = task
        await task.value
    }

    /// Reconstructs a real mesh from a scan's captured frames (PhotogrammetrySession),
    /// then runs the MeshKit pipeline on it. Reports progress via
    /// `reconstructionProgress`.
    func reconstructScan(_ scan: ScanRecord, for animalID: UUID) async -> ProcessedScan? {
        guard ReconstructionDriver.isSupported else {
            errorMessage = "This device can't reconstruct scans."
            return nil
        }
        let framesDir = library.framesDirectory(animalID, scan.id)
        let usdz = library.artifactURL(animalID, scan.id, .modelUSDZ)
        let start = Date()
        reconstructionProgress = 0
        defer { reconstructionProgress = nil }

        do {
            var updated = scan; updated.status = .reconstructing
            try? await library.save(updated, for: animalID)

            _ = try await ReconstructionDriver.reconstruct(
                framesDirectory: framesDir, outputURL: usdz, detail: scan.detail
            ) { fraction in
                Task { @MainActor in self.reconstructionProgress = fraction * 0.9 }
            }

            // Load, orient (Y-up → Z-up), and run the geometry pipeline. A
            // reconstructed back has no floor, so disable the top-region filter.
            let mesh = try USDZMeshLoader.loadTriangleMesh(from: usdz).transformed(by: Self.yUpToZUp)
            reconstructionProgress = 0.95
            var result = try await processor.process(
                mesh: mesh, animalID: animalID, scanID: scan.id,
                stationSpacing: scan.stationSpacingMeters, topRegionMinHeight: -1_000_000)
            // The interactive 3D view uses the photo-textured reconstruction.
            result.exports.texturedModelURL = usdz
            result.exports.reportPDF = generateReportPDF(result, animalID: animalID, scanID: scan.id)

            updated = scan; updated.status = .complete
            updated.processingSeconds = Date().timeIntervalSince(start)
            try await library.save(updated, for: animalID)
            return result
        } catch {
            errorMessage = "Reconstruction failed: \(error.localizedDescription)"
            var updated = scan; updated.status = .failed
            try? await library.save(updated, for: animalID)
            return nil
        }
    }

    /// Loads the viewable result for an already-completed scan WITHOUT re-running
    /// photogrammetry. For a reconstructed scan it reloads the saved USDZ and runs
    /// only the fast MeshKit pipeline (seconds); for a demo scan it re-runs the
    /// synthetic pipeline (also fast). Returns nil if nothing is available.
    func loadResult(for scan: ScanRecord, animalID: UUID) async -> ProcessedScan? {
        // Reconstructed scans have captured frames + a saved model.usdz.
        if hasCapturedFrames(animalID: animalID, scanID: scan.id) {
            let usdz = library.artifactURL(animalID, scan.id, .modelUSDZ)
            await library.materialize(usdz)
            guard FileManager.default.fileExists(atPath: usdz.path) else { return nil }
            do {
                let mesh = try USDZMeshLoader.loadTriangleMesh(from: usdz).transformed(by: Self.yUpToZUp)
                var result = try await processor.process(
                    mesh: mesh, animalID: animalID, scanID: scan.id,
                    stationSpacing: scan.stationSpacingMeters, topRegionMinHeight: -1_000_000)
                result.exports.texturedModelURL = usdz
                result.exports.reportPDF = generateReportPDF(result, animalID: animalID, scanID: scan.id)
                return result
            } catch {
                errorMessage = "Couldn't load scan result: \(error.localizedDescription)"
                return nil
            }
        }
        // Demo/synthetic completed scan — cheap to reproduce.
        return await processScan(scan, for: animalID)
    }

    /// Runs the geometry + export pipeline for a scan and marks it complete.
    /// Until CaptureKit/ReconstructionKit exist, the input is a synthetic back
    /// mesh so the whole flow is exercisable end-to-end.
    func processScan(_ scan: ScanRecord, for animalID: UUID) async -> ProcessedScan? {
        let mesh = SyntheticBackMesh.make().mesh
        let start = Date()
        do {
            var result = try await processor.process(
                mesh: mesh, animalID: animalID, scanID: scan.id,
                stationSpacing: scan.stationSpacingMeters
            )
            result.exports.reportPDF = generateReportPDF(result, animalID: animalID, scanID: scan.id)
            var updated = scan
            updated.status = .complete
            updated.processingSeconds = Date().timeIntervalSince(start)
            try await library.save(updated, for: animalID)
            return result
        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
            var updated = scan
            updated.status = .failed
            try? await library.save(updated, for: animalID)
            return nil
        }
    }
}

/// Lightweight device identification for scan metadata (Design §10, §12.1).
enum DeviceInfo {
    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// Hardware model identifier, e.g. `iPhone16,1`.
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
