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
        /// Single-page cross-section report (set by AppModel after processing).
        var reportPDF: URL?

        /// The best model to display in the interactive 3D view: the textured
        /// reconstruction if present, else the ROI mesh.
        var viewableModelURL: URL? { texturedModelURL ?? roiUSDZ }

        /// Files suitable for a share sheet.
        var shareables: [URL] {
            [reportPDF, viewableModelURL, roiSTL, sectionsDXF, sectionsCSV, metricsCSV].compactMap { $0 }
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
        let normalized = LongAxisNormalizer.normalized(mesh, topRegionMinHeight: topRegionMinHeight).mesh
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
        let sections = CrossSectionExtractor.extract(cropped, curve: curve, atArcLengths: stationArcs, configuration: cfg)
        let metrics = sections.map { SectionMetricsCalculator.metrics(for: $0, curve: curve) }

        // Sample the topline "rocker" from withers to tail at ~1 cm.
        var rocker: [SIMD2<Double>] = []
        let steps = max(Int(abs(endS - startS) / 0.01), 1)
        for i in 0...steps {
            let rs = startS + (endS - startS) * Double(i) / Double(steps)
            rocker.append(SIMD2<Double>(rs, curve.point(atArcLength: rs).z))
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
            exports: .init(
                roiOBJ: roiOBJ, roiUSDZ: writtenUSDZ, roiSTL: roiSTL, sectionsDXF: sectionsDXF,
                sectionsCSV: sectionsCSV, metricsCSV: metricsCSV, spineJSON: spineJSON,
                texturedModelURL: nil
            )
        )
    }
}
