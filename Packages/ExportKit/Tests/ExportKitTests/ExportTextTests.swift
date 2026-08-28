import Testing
import Foundation
import simd
import MeshKit
@testable import ExportKit

@Suite("Text exporters (CSV / DXF / OBJ / PLY)")
struct ExportTextTests {

    /// A straight-cylinder scan reduced to sections + metrics.
    private func sampleSections() -> (sections: [CrossSection], metrics: [SectionMetrics]) {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 80, segmentsAround: 48)
        let curve = SpineCurveFitter.fit(mesh)!.curve
        let roi = (curve.xMin + 0.1)...(curve.xMax - 0.1)
        let sections = CrossSectionExtractor.extract(mesh, curve: curve, roiArcLength: roi)
        let metrics = sections.map { SectionMetricsCalculator.metrics(for: $0, curve: curve) }
        return (sections, metrics)
    }

    @Test("sections.csv has a header and one row per polyline vertex")
    func sectionsCSV() {
        let (sections, _) = sampleSections()
        let csv = CSVWriter.sectionsCSV(sections)
        let lines = csv.split(separator: "\n")

        #expect(lines.first == "station_index,arc_length_cm,point_index,u_cm,v_cm")
        let totalPoints = sections.reduce(0) { $0 + $1.points2D.count }
        #expect(lines.count == totalPoints + 1)
        // Every data row has five columns.
        #expect(lines.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 5 })
    }

    @Test("metrics.csv row count and unit conversions")
    func metricsCSV() {
        let (_, metrics) = sampleSections()
        let csv = CSVWriter.metricsCSV(metrics)
        let lines = csv.split(separator: "\n")

        #expect(lines.first == "station_index,arc_length_cm,width_below_spine_cm,angle_left_deg,angle_right_deg,symmetry_rms_mm,reliable")
        #expect(lines.count == metrics.count + 1)

        // First data row: arc_length_cm ≈ metres×100 of the first station.
        let cols = lines[1].split(separator: ",").map { Double($0)! }
        #expect(abs(cols[1] - metrics[0].arcLength * 100) < 1e-3)
        #expect(abs(cols[5] - metrics[0].symmetricErrorRMS * 1000) < 1e-3)
    }

    @Test("DXF has one closed polyline per station on named layers")
    func dxf() {
        let (sections, _) = sampleSections()
        let dxf = DXFWriter.dxf(from: sections)

        #expect(dxf.hasPrefix("0\nSECTION\n"))
        #expect(dxf.contains("\nEOF\n"))
        #expect(dxf.contains("STATION_0000"))
        // One POLYLINE entity per section.
        let polylineCount = dxf.components(separatedBy: "\nPOLYLINE\n").count - 1
        #expect(polylineCount == sections.count)
        // Sections from a closed tube export with the closed flag set.
        #expect(dxf.contains("\n70\n1\n"))
    }

    @Test("OBJ export round-trips through MeshIO")
    func obj() throws {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 10, segmentsAround: 12)
        let text = OBJWriter.obj(from: mesh)
        let decoded = try MeshIO.mesh(fromOBJ: text)
        #expect(decoded.vertexCount == mesh.vertexCount)
        #expect(decoded.indices == mesh.indices)
    }

    @Test("Binary STL has correct header, count and byte size")
    func stl() {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 10, segmentsAround: 12)
        let data = STLWriter.binarySTL(from: mesh)
        // 80-byte header + UInt32 count + 50 bytes per triangle.
        #expect(data.count == 84 + mesh.triangleCount * 50)
        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(count) == mesh.triangleCount)
    }

    @Test("PLY header matches geometry counts")
    func ply() {
        let mesh = SyntheticBackMesh.straightCylinder(segmentsAlong: 10, segmentsAround: 12)
        let text = PLYWriter.ply(from: mesh)
        #expect(text.hasPrefix("ply\n"))
        #expect(text.contains("element vertex \(mesh.vertexCount)\n"))
        #expect(text.contains("element face \(mesh.triangleCount)\n"))
        // Body line count = header + vertices + faces.
        let bodyLines = text.split(separator: "\n").count
        let headerLines = 10
        #expect(bodyLines == headerLines + mesh.vertexCount + mesh.triangleCount)
    }
}
