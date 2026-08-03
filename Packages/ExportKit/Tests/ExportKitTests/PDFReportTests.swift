import Testing
import Foundation
import simd
import MeshKit
@testable import ExportKit

@Suite("PDF report")
struct PDFReportTests {

    /// Runs the geometry pipeline on the profiled synthetic back to get real
    /// withers-anchored sections + topline.
    private func sample() -> (sections: [CrossSection], rocker: [SIMD2<Double>]) {
        let (mesh, _) = SyntheticBackMesh.make()
        let norm = LongAxisNormalizer.normalized(mesh).mesh
        let curve = SpineCurveFitter.fit(norm)!.curve
        let marks = LandmarkDetector.detect(on: curve)
        let cropped = ROICropper.crop(norm, curve: curve, roiArcLength: marks.roiArcLengthRange).mesh

        var stations: [Double] = []
        var s = marks.withersArcLength
        while s <= marks.tailArcLength { stations.append(s); s += 0.1016 }
        // Match the app: clip sections to ±8 in of the spine.
        var cfg = CrossSectionExtractor.Configuration(); cfg.lateralHalfWidth = 0.2032
        let sections = CrossSectionExtractor.extract(cropped, curve: curve, atArcLengths: stations, configuration: cfg)

        var rocker: [SIMD2<Double>] = []
        let steps = max(Int(abs(marks.tailArcLength - marks.withersArcLength) / 0.01), 1)
        for i in 0...steps {
            let a = marks.withersArcLength + (marks.tailArcLength - marks.withersArcLength) * Double(i) / Double(steps)
            rocker.append(SIMD2<Double>(a, curve.point(atArcLength: a).z))
        }
        // The synthetic mesh is ~1.2 m long; scale the topline to a realistic
        // ~0.85 m back so the two-page true-scale split is exercised as it would
        // be on real data.
        let span = (rocker.last!.x - rocker.first!.x)
        let factor = 0.85 / span
        let x0 = rocker.first!.x
        rocker = rocker.map { SIMD2<Double>(($0.x - x0) * factor, $0.y * factor) }
        return (sections, rocker)
    }

    @Test("Produces a valid PDF and writes a sample to inspect")
    func producesPDF() throws {
        let (sections, rocker) = sample()
        #expect(sections.count >= 6)

        let data = PDFReportWriter.pdfData(
            animalName: "Penelope (mule)", dateText: "2026-08-03",
            sections: sections, rocker: rocker, imperial: true, pageSize: .tabloid)

        #expect(data.count > 1000)
        // PDF magic bytes.
        #expect(data.prefix(4) == Data("%PDF".utf8))

        try data.write(to: URL(fileURLWithPath: "/tmp/saddleback_report.pdf"))

        // Letter: sections must drop below 1:1 so the widest section fits.
        let letter = PDFReportWriter.pdfData(
            animalName: "Penelope (mule)", dateText: "2026-08-03",
            sections: sections, rocker: rocker, imperial: true, pageSize: .letter)
        try letter.write(to: URL(fileURLWithPath: "/tmp/saddleback_letter.pdf"))
    }
}
