import Testing
import Foundation
import simd
import CoreGraphics
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

@Suite("PDF layout limits")
struct PDFLayoutTests {

    /// Sections at a fine station spacing — a 2 cm spacing on a long back yields
    /// far more than the fan or the legend can hold.
    private func manySections() -> (sections: [CrossSection], rocker: [SIMD2<Double>], withers: Double) {
        let (mesh, _) = SyntheticBackMesh.make()
        let norm = LongAxisNormalizer.normalized(mesh).mesh
        let curve = SpineCurveFitter.fit(norm)!.curve
        let marks = LandmarkDetector.detect(on: curve)
        let cropped = ROICropper.crop(norm, curve: curve, roiArcLength: marks.roiArcLengthRange).mesh

        var stations: [Double] = []
        var s = marks.withersArcLength
        while s <= marks.tailArcLength { stations.append(s); s += 0.01 }
        var cfg = CrossSectionExtractor.Configuration(); cfg.lateralHalfWidth = 0.2032
        let sections = CrossSectionExtractor.extract(cropped, curve: curve, atArcLengths: stations, configuration: cfg)

        var rocker: [SIMD2<Double>] = []
        let steps = max(Int(abs(marks.tailArcLength - marks.withersArcLength) / 0.01), 1)
        for i in 0...steps {
            let a = marks.withersArcLength + (marks.tailArcLength - marks.withersArcLength) * Double(i) / Double(steps)
            rocker.append(SIMD2<Double>(a, curve.point(atArcLength: a).z))
        }
        return (sections, rocker, marks.withersArcLength)
    }

    @Test("A long section list is thinned so the fan and legend stay on the page")
    func thinsToFit() {
        let (sections, rocker, withers) = manySections()
        let page = PDFPageSize.letter.landscapeSize

        // Room left for the fan on Letter once title, scale bars and a ~10 cm-deep
        // section are accounted for. Supplied explicitly rather than measured off
        // the fixture: the synthetic tube's sections are CLOSED loops ~0.5 m deep,
        // which no page can hold — real backs are shallow open arcs (see
        // SyntheticBackMesh). The arithmetic under test is the same either way.
        let heightForFan: CGFloat = 260

        // Whichever of the fan and the legend runs out of room first is the limit.
        let fanCapacity = Int(heightForFan / PDFReportWriter.minFanOffset) + 1
        let capacity = min(fanCapacity, PDFReportWriter.legendLayout(page: page).capacity)
        // The fixture must actually overflow, or this proves nothing.
        #expect(sections.count > capacity)

        let (shown, step) = PDFReportWriter.displayedSections(sections, page: page, heightForFan: heightForFan)
        #expect(step > 1)
        #expect(shown.count <= capacity)

        // The fan fits at a legible spacing…
        let gaps = CGFloat(max(shown.count - 1, 0))
        #expect(gaps == 0 || heightForFan / gaps >= PDFReportWriter.minFanOffset)

        // …and the legend box fits the page height.
        let layout = PDFReportWriter.legendLayout(page: page)
        let rows = min(shown.count, layout.rows)
        let boxH = PDFReportWriter.legendPad * 2 + PDFReportWriter.legendTitleH
            + PDFReportWriter.legendRowH * CGFloat(rows)
        #expect(boxH <= page.height - 2 * 40)

        // And it still renders two pages.
        let data = PDFReportWriter.pdfData(animalName: "Overflow", dateText: "today",
                                           sections: sections, rocker: rocker, imperial: true,
                                           pageSize: .letter, withersArcLength: withers)
        #expect(!data.isEmpty)
        let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)
        #expect(doc?.numberOfPages == 2)
    }

    /// The withers marker is placed by ARC LENGTH. It used to be drawn at
    /// `rocker[0]`, which is the first *reliable* station — a different station
    /// entirely whenever the withers section is dropped as unreliable.
    @Test("Topline height is interpolated at the withers arc length")
    func withersHeightByArc() {
        let rocker = [
            SIMD2<Double>(1.0, 0.10),
            SIMD2<Double>(1.5, 0.20),
            SIMD2<Double>(2.0, 0.30),
        ]
        // Exactly on a sample, and halfway between two.
        #expect(abs(PDFReportWriter.height(of: rocker, atArc: 1.5)! - 0.20) < 1e-12)
        #expect(abs(PDFReportWriter.height(of: rocker, atArc: 1.75)! - 0.25) < 1e-12)
        // Outside the sampled span: no marker rather than a wrong one.
        #expect(PDFReportWriter.height(of: rocker, atArc: 0.5) == nil)
        #expect(PDFReportWriter.height(of: rocker, atArc: 2.5) == nil)
    }
}
