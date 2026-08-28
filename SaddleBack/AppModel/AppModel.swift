import Foundation
import Observation
import CoreGraphics
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

    // MARK: - Share / import

    /// Builds a shareable archive of one scan; returns its URL (in a temp dir).
    func exportScanArchive(animalID: UUID, scanID: UUID) async -> URL? {
        do { return try await library.exportScan(animalID: animalID, scanID: scanID) }
        catch { errorMessage = "Couldn't build scan archive: \(error.localizedDescription)"; return nil }
    }

    /// Builds a shareable archive of the whole animal store; returns its URL.
    func exportAllArchive() async -> URL? {
        do { return try await library.exportAll() }
        catch { errorMessage = "Couldn't build archive: \(error.localizedDescription)"; return nil }
    }

    /// Imports scans from an archive and reloads the roster. Returns how many scans
    /// were imported.
    @discardableResult
    func importArchive(from url: URL) async -> Int {
        do {
            let count = try await library.importArchive(from: url)
            await loadAnimals()
            return count
        } catch {
            errorMessage = "Couldn't import archive: \(error.localizedDescription)"
            return 0
        }
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
        // Offscreen snapshot of the painted 3D model (with tracings) to embed.
        var modelImage: CGImage?
        if let surface = result.exports.paintedSurfaceURL {
            modelImage = Model3DSnapshot.render(surfaceURL: surface,
                                                tracingsURL: result.exports.tracingsURL,
                                                size: CGSize(width: 1600, height: 1000))
        }
        do {
            try PDFReportWriter.write(animalName: name, dateText: date,
                                      sections: result.sections, rocker: result.rocker,
                                      imperial: imperial, pageSize: pageSize,
                                      modelImage: modelImage, to: url)
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
        let lidarOBJ = library.framesDirectory(animalID, scan.id).appendingPathComponent("lidar.obj")
        let hasLidarMesh = FileManager.default.fileExists(atPath: lidarOBJ.path)
        guard hasLidarMesh
                || (ReconstructionDriver.isSupported && hasCapturedFrames(animalID: animalID, scanID: scan.id))
        else { return }
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
        let framesDir = library.framesDirectory(animalID, scan.id)
        let lidarOBJ = framesDir.appendingPathComponent("lidar.obj")
        await library.materialize(lidarOBJ)
        let hasLidarMesh = FileManager.default.fileExists(atPath: lidarOBJ.path)

        // The LiDAR path uses ARKit's fused scene mesh directly (no photogrammetry);
        // only the TrueDepth path needs a PhotogrammetrySession.
        guard hasLidarMesh || ReconstructionDriver.isSupported else {
            errorMessage = "This device can't reconstruct scans."
            return nil
        }

        let start = Date()
        reconstructionProgress = 0
        defer { reconstructionProgress = nil }

        var updated = scan; updated.status = .reconstructing
        try? await library.save(updated, for: animalID)

        do {
            let mesh: TriangleMesh
            let textured: URL?
            let fused: URL?
            if hasLidarMesh {
                // Fused LiDAR scene mesh (ARKit Y-up) → Z-up; already cropped to the
                // scanned region, so no floor to strip.
                mesh = try MeshIO.readOBJ(at: lidarOBJ).transformed(by: Self.yUpToZUp)
                textured = nil
                fused = lidarOBJ
                reconstructionProgress = 0.6
            } else {
                let usdz = library.artifactURL(animalID, scan.id, .modelUSDZ)
                _ = try await ReconstructionDriver.reconstruct(
                    framesDirectory: framesDir, outputURL: usdz, detail: scan.detail
                ) { fraction in
                    Task { @MainActor in self.reconstructionProgress = fraction * 0.9 }
                }
                mesh = try USDZMeshLoader.loadTriangleMesh(from: usdz).transformed(by: Self.yUpToZUp)
                textured = usdz
                fused = nil
            }

            reconstructionProgress = 0.95
            let result = try await makeResult(mesh: mesh, textured: textured, fused: fused, scan: scan, animalID: animalID)
            updated = scan; updated.status = .complete
            updated.processingSeconds = Date().timeIntervalSince(start)
            try await library.save(updated, for: animalID)
            return result
        } catch {
            errorMessage = "Reconstruction failed: \(error.localizedDescription)"
            updated = scan; updated.status = .failed
            try? await library.save(updated, for: animalID)
            return nil
        }
    }

    /// Loads the viewable result for an already-completed scan by reloading the
    /// saved mesh and running only the fast MeshKit pipeline (seconds). Returns nil
    /// if no reconstructed mesh is available.
    func loadResult(for scan: ScanRecord, animalID: UUID) async -> ProcessedScan? {
        if let (mesh, textured, fused) = await loadReconstructedMesh(scan, animalID: animalID) {
            do { return try await makeResult(mesh: mesh, textured: textured, fused: fused, scan: scan, animalID: animalID) }
            catch {
                errorMessage = "Couldn't load scan result: \(error.localizedDescription)"
                return nil
            }
        }
        // No reconstructed mesh available.
        return nil
    }

    /// Loads the best reconstructed mesh for a scan, oriented into MeshKit's Z-up
    /// frame: the fused **LiDAR** mesh (`lidar.obj`) if present, else the
    /// photogrammetry `model.usdz`. Returns the mesh, the textured-model URL, and
    /// the fused-mesh URL (for the 3D viewer).
    private func loadReconstructedMesh(_ scan: ScanRecord, animalID: UUID) async -> (mesh: TriangleMesh, textured: URL?, fused: URL?)? {
        let lidarOBJ = library.framesDirectory(animalID, scan.id).appendingPathComponent("lidar.obj")
        await library.materialize(lidarOBJ)
        if FileManager.default.fileExists(atPath: lidarOBJ.path),
           let m = try? MeshIO.readOBJ(at: lidarOBJ) {
            return (m.transformed(by: Self.yUpToZUp), nil, lidarOBJ)
        }
        let usdz = library.artifactURL(animalID, scan.id, .modelUSDZ)
        await library.materialize(usdz)
        if FileManager.default.fileExists(atPath: usdz.path),
           let m = try? USDZMeshLoader.loadTriangleMesh(from: usdz) {
            return (m.transformed(by: Self.yUpToZUp), usdz, nil)
        }
        return nil
    }

    /// Runs the MeshKit geometry + export pipeline on an already-reconstructed mesh
    /// (Z-up, no floor to strip), attaching the textured/fused models + generated PDF.
    private func makeResult(mesh: TriangleMesh, textured: URL?, fused: URL?, scan: ScanRecord, animalID: UUID) async throws -> ProcessedScan {
        var result = try await processor.process(
            mesh: mesh, animalID: animalID, scanID: scan.id,
            stationSpacing: scan.stationSpacingMeters, topRegionMinHeight: -1_000_000)
        result.exports.texturedModelURL = textured
        result.exports.fusedModelURL = fused
        let framesDir = library.framesDirectory(animalID, scan.id)
        let cloud = framesDir.appendingPathComponent("pointcloud.bin")
        await library.materialize(cloud)
        result.exports.pointCloudURL = FileManager.default.fileExists(atPath: cloud.path) ? cloud : nil
        let surface = framesDir.appendingPathComponent("surface.bin")
        await library.materialize(surface)
        if FileManager.default.fileExists(atPath: surface.path) {
            result.exports.paintedSurfaceURL = surface
            // Also emit a colored PLY of the painted surface for export/sharing.
            if let painted = try? PaintedMeshIO.read(surface) {
                let ply = library.exportsDirectory(animalID, scan.id).appendingPathComponent("surface.ply")
                if (try? PLYWriter.writeColored(positions: painted.positions, colors: painted.colors,
                                                indices: painted.indices, to: ply)) != nil {
                    result.exports.paintedPLY = ply
                }
            }
            // Spine + section tracings, mapped from the normalized frame back into
            // the capture/world frame of the painted surface, for overlay.
            let tracings = framesDir.appendingPathComponent("tracings.bin")
            if (try? PolylineIO.write(worldTracings(from: result), to: tracings)) != nil {
                result.exports.tracingsURL = tracings
            }
        }
        result.exports.reportPDF = generateReportPDF(result, animalID: animalID, scanID: scan.id)
        return result
    }

    /// Maps the spine polyline + each cross-section (normalized Z-up frame) back to
    /// the capture/world frame of the painted surface, so they can be overlaid.
    /// world = yUpToZUp⁻¹ · N⁻¹ · normalized  (N = the pipeline's normalize transform).
    private func worldTracings(from result: ProcessedScan) -> [[SIMD3<Float>]] {
        let inv = simd_inverse(Self.yUpToZUp) * simd_inverse(result.normalizeTransform)
        func toWorld(_ p: SIMD3<Double>) -> SIMD3<Float> {
            let v = inv * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
            return SIMD3<Float>(v.x, v.y, v.z)
        }
        var lines: [[SIMD3<Float>]] = [result.spinePolyline.map(toWorld)]
        for section in result.sections where section.points3D.count > 1 {
            lines.append(section.points3D.map(toWorld))
        }
        return lines
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
