import Foundation
import simd
import MeshKit
import ExportKit

/// Codable summary of the spine fit and landmarks, persisted as `spine.json`
/// (Design §10). Uses primitive fields so it round-trips without SIMD.
nonisolated struct SpineSummary: Codable, Sendable {
    struct Point: Codable, Sendable { var x, y, z: Double }

    var withers: Point
    var croup: Point
    var loin: Point
    var tailBase: Point
    var caudalSign: Double
    var withersArcLength: Double
    var frontCutoffArcLength: Double
    var tailArcLength: Double
    var totalArcLength: Double
    var roiLowerArcLength: Double
    var roiUpperArcLength: Double

    init(landmarks m: Landmarks, totalArcLength: Double) {
        func p(_ v: SIMD3<Double>) -> Point { Point(x: v.x, y: v.y, z: v.z) }
        withers = p(m.withersPoint)
        croup = p(m.croupPoint)
        loin = p(m.loinPoint)
        tailBase = p(m.tailBasePoint)
        caudalSign = m.caudalSign
        withersArcLength = m.withersArcLength
        frontCutoffArcLength = m.frontCutoffArcLength
        tailArcLength = m.tailArcLength
        self.totalArcLength = totalArcLength
        roiLowerArcLength = m.roiArcLengthRange.lowerBound
        roiUpperArcLength = m.roiArcLengthRange.upperBound
    }
}

/// The outcome of processing a mesh through the geometry + export pipeline.
nonisolated struct ProcessedScan: Sendable {
    var spine: SpineSummary
    var sectionCount: Int
    var metrics: [SectionMetrics]
    var sections: [CrossSection]
    /// Topline "rocker": sampled `(arcLength, height)` pairs along the ROI, in metres.
    var rocker: [SIMD2<Double>]
    var roiTriangleCount: Int
    /// Spine curve sampled in 3D over the ROI (normalized Z-up frame), for the
    /// tracings overlaid on the 3D model.
    var spinePolyline: [SIMD3<Double>]
    /// World→normalized rigid transform applied by `LongAxisNormalizer` (rotation
    /// about vertical). Invertible to map spine/sections back to the capture frame.
    var normalizeTransform: simd_float4x4
    var exports: Exports

    struct Exports: Sendable {
        var roiOBJ: URL
        var roiUSDZ: URL?
        var roiSTL: URL
        var sectionsDXF: URL
        var sectionsCSV: URL
        var metricsCSV: URL
        var spineJSON: URL
        /// Photo-textured reconstruction (set after reconstruction); nil for the
        /// synthetic demo path.
        var texturedModelURL: URL?
        /// Full fused LiDAR scene mesh (OBJ), the whole scanned back — set for the
        /// LiDAR path. Loads reliably in SceneKit (no ModelIO USD dependency).
        var fusedModelURL: URL?
        /// Full uncropped captured point cloud (coverage-colored) for the diagnostic
        /// point-cloud viewer — set for the LiDAR path.
        var pointCloudURL: URL?
        /// Photo-painted surface mesh (`PaintedMeshIO`) for the 3D viewer — set for
        /// the single-shot LiDAR path.
        var paintedSurfaceURL: URL?
        /// Photo-painted surface as a colored PLY, for export/sharing.
        var paintedPLY: URL?
        /// Spine + cross-section tracings (world/capture frame) for overlay on the
        /// painted 3D model — set by AppModel after processing.
        var tracingsURL: URL?
        /// Single-page cross-section report (set by AppModel after processing).
        var reportPDF: URL?

        /// The best model to display in the interactive 3D view: the photo-textured
        /// reconstruction, else the full fused LiDAR mesh, else the ROI mesh.
        var viewableModelURL: URL? { texturedModelURL ?? fusedModelURL ?? roiUSDZ }

        /// Files suitable for a share sheet.
        var shareables: [URL] {
            [reportPDF, paintedPLY, viewableModelURL, roiSTL, sectionsDXF, sectionsCSV, metricsCSV].compactMap { $0 }
        }
    }
}

/// Orchestrates the full geometry pipeline (Design §7 + §9) and writes the
/// export artifacts (§11) into a scan's directory. Isolated to an actor so the
/// CPU-heavy fit and disk I/O stay off the main actor.
actor ScanProcessor {

    enum ProcessingError: Error, Equatable {
        case spineFitFailed
        case emptyROI
    }

    private let library: ScanLibrary

    init(library: ScanLibrary) {
        self.library = library
    }

    /// Runs normalize → spine → landmarks → ROI crop → sections → metrics, then
    /// exports OBJ/USDZ/DXF/CSV and `spine.json`. USDZ export is best-effort (it
    /// requires the Model I/O USD plugin, unavailable in some contexts).
    /// - Parameter topRegionMinHeight: vertical threshold that separates the
    ///   animal's top from legs/ground (Design §7.1). Use 0.8 m for a
    ///   gravity-aligned LiDAR world mesh; use a large negative value for a
    ///   reconstructed back mesh (no floor/legs to strip).
    func process(
        mesh: TriangleMesh, animalID: UUID, scanID: UUID,
        stationSpacing: Double = 0.02, topRegionMinHeight: Float = 0.8
    ) throws -> ProcessedScan {
        // Geometry pipeline.
        let normResult = LongAxisNormalizer.normalized(mesh, topRegionMinHeight: topRegionMinHeight)
        let normalized = normResult.mesh
        var spineConfig = SpineCurveFitter.Configuration()
        spineConfig.topRegionMinHeight = topRegionMinHeight
        guard let fit = SpineCurveFitter.fit(normalized, configuration: spineConfig) else { throw ProcessingError.spineFitFailed }
        let curve = fit.curve
        let marks = LandmarkDetector.detect(on: curve)
        let roi = marks.roiArcLengthRange

        let cropped = ROICropper.crop(normalized, curve: curve, roiArcLength: roi).mesh
        guard cropped.triangleCount > 0 else { throw ProcessingError.emptyROI }

        // Stations anchored at the top of the withers, stepping caudally toward
        // the tail by the chosen spacing (Design §9.2, saddle-fitter workflow).
        let startS = marks.withersArcLength
        let endS = marks.tailArcLength
        let direction: Double = endS >= startS ? 1 : -1
        var stationArcs: [Double] = []
        var s = startS
        while (direction > 0 && s <= endS + 1e-9) || (direction < 0 && s >= endS - 1e-9) {
            stationArcs.append(s)
            s += direction * stationSpacing
        }

        var cfg = CrossSectionExtractor.Configuration()
        cfg.lateralHalfWidth = 0.2032   // 8 inches each side of the spine (fits 11×17 at true scale)
        let allSections = CrossSectionExtractor.extract(cropped, curve: curve, atArcLengths: stationArcs, configuration: cfg)
        let allMetrics = allSections.map { SectionMetricsCalculator.metrics(for: $0, curve: curve) }

        // Drop cross-sections that don't fully cover the back (one side missing
        // during capture): keep only those reaching ±5 cm on both sides of the
        // spine (`isReliable`). Dropped everywhere downstream — sections, metrics,
        // tracings, the section fan, and the CSV/DXF exports. Station indices keep
        // their original values so a gap in numbering signals a dropped station.
        let kept = zip(allSections, allMetrics).filter { $0.1.isReliable }
        let sections = kept.map(\.0)
        let metrics = kept.map(\.1)

        // Sample the topline "rocker" (arc, height) and the 3D spine polyline over
        // the ROI at ~1 cm.
        var rocker: [SIMD2<Double>] = []
        var spinePolyline: [SIMD3<Double>] = []
        let steps = max(Int(abs(endS - startS) / 0.01), 1)
        for i in 0...steps {
            let rs = startS + (endS - startS) * Double(i) / Double(steps)
            let p = curve.point(atArcLength: rs)
            rocker.append(SIMD2<Double>(rs, p.z))
            spinePolyline.append(p)
        }

        // Ensure the destination directories exist.
        let exportsDir = library.exportsDirectory(animalID, scanID)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        // Export artifacts.
        let roiOBJ = library.artifactURL(animalID, scanID, .roiOBJ)
        try OBJWriter.write(cropped, to: roiOBJ)

        let sectionsDXF = exportsDir.appendingPathComponent("sections.dxf")
        try DXFWriter.write(sections, to: sectionsDXF)

        let sectionsCSV = exportsDir.appendingPathComponent("sections.csv")
        try CSVWriter.write(sections: sections, to: sectionsCSV)

        let metricsCSV = exportsDir.appendingPathComponent("metrics.csv")
        try CSVWriter.write(metrics: metrics, to: metricsCSV)

        // ROI mesh as USDZ (separate from the textured reconstruction model.usdz,
        // which must not be overwritten) and as STL for CAD/3D-print.
        let roiUSDZ = exportsDir.appendingPathComponent("roi.usdz")
        var writtenUSDZ: URL? = nil
        do { try USDZWriter.write(cropped, to: roiUSDZ); writtenUSDZ = roiUSDZ } catch { writtenUSDZ = nil }

        let roiSTL = exportsDir.appendingPathComponent("roi.stl")
        try STLWriter.write(cropped, to: roiSTL)

        let spine = SpineSummary(landmarks: marks, totalArcLength: curve.totalArcLength)
        let spineJSON = library.artifactURL(animalID, scanID, .spineJSON)
        try ScanLibrary.encoder.encode(spine).write(to: spineJSON, options: .atomic)

        return ProcessedScan(
            spine: spine,
            sectionCount: sections.count,
            metrics: metrics,
            sections: sections,
            rocker: rocker,
            roiTriangleCount: cropped.triangleCount,
            spinePolyline: spinePolyline,
            normalizeTransform: normResult.transform,
            exports: .init(
                roiOBJ: roiOBJ, roiUSDZ: writtenUSDZ, roiSTL: roiSTL, sectionsDXF: sectionsDXF,
                sectionsCSV: sectionsCSV, metricsCSV: metricsCSV, spineJSON: spineJSON,
                texturedModelURL: nil
            )
        )
    }
}
