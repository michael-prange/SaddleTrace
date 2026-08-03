import SwiftUI
import Charts
import MeshKit

/// Visual summary of a processed scan: an interactive cross-section drawing, the
/// topline rocker, width and tree-angle profiles, plus USDZ Quick Look and a
/// share sheet for the exported files.
struct ResultView: View {
    let result: ProcessedScan

    @State private var stationIndex = 0
    @State private var showing3D = false
    @AppStorage("measurementSystem") private var systemRaw = MeasurementSystem.metric.rawValue

    private var system: MeasurementSystem { MeasurementSystem(rawValue: systemRaw) ?? .metric }

    var body: some View {
        List {
            summarySection
            if !result.sections.isEmpty { crossSectionSection }
            rockerSection
            widthSection
            treeAngleSection
            exportSection
        }
        .sheet(isPresented: $showing3D) {
            if let url = result.exports.viewableModelURL {
                Model3DView(url: url)
            }
        }
        .onAppear {
            // Start on the first reliable (well-formed) station rather than the
            // partial section at the front cutoff.
            if stationIndex == 0, let first = result.metrics.firstIndex(where: \.isReliable) {
                stationIndex = first
            }
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        Section("Summary") {
            LabeledContent("Back length", value: system.lengthString(result.spine.totalArcLength))
            LabeledContent("Cross-sections", value: "\(result.sectionCount)")
            LabeledContent("Reliable stations", value: "\(reliableCount) of \(result.sectionCount)")
            LabeledContent("ROI triangles", value: "\(result.roiTriangleCount)")
        }
    }

    private var reliableCount: Int { result.metrics.filter(\.isReliable).count }

    // MARK: Cross-section

    private var crossSectionSection: some View {
        Section("Cross-section") {
            let clamped = min(stationIndex, result.sections.count - 1)
            let section = result.sections[clamped]

            CrossSectionShape(points: section.points2D, isClosed: section.isClosed)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                .background(SpineMarker(points: section.points2D))
                .frame(height: 220)
                .padding(.vertical, 4)

            VStack(alignment: .leading) {
                Text("Station \(section.stationIndex) · \(system.lengthString(section.arcLength)) along the back")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(clamped) },
                        set: { stationIndex = Int($0.rounded()) }
                    ),
                    in: 0...Double(result.sections.count - 1),
                    step: 1
                )
            }
        }
    }

    // MARK: Charts

    private var alongLabel: String { "Along back (\(system.lengthUnit))" }

    private var rockerSection: some View {
        Section("Topline (rocker)") {
            Chart(rockerPoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Height (\(system.lengthUnit))", p.value))
            }
            .frame(height: 160)
        }
    }

    private var widthSection: some View {
        Section("Width at spine level") {
            Chart(widthPoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Width (\(system.lengthUnit))", p.value))
            }
            .frame(height: 160)
        }
    }

    private var treeAngleSection: some View {
        Section("Tree angles") {
            Chart(treeAnglePoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Angle (°)", p.value))
                    .foregroundStyle(by: .value("Side", p.series))
            }
            .chartForegroundStyleScale(["Left": Color.blue, "Right": Color.orange])
            .frame(height: 160)
        }
    }

    // MARK: Exports

    private var exportSection: some View {
        Section {
            if result.exports.viewableModelURL != nil {
                Button {
                    showing3D = true
                } label: {
                    Label("View 3D Model", systemImage: "rotate.3d")
                }
            }
            if let pdf = result.exports.reportPDF {
                ShareLink(item: pdf) {
                    Label("Share Cross-Section PDF", systemImage: "doc.richtext")
                }
            }
            ShareLink(items: result.exports.shareables) {
                Label("Share All Exports (PDF · STL · USDZ · DXF · CSV)", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Drag to rotate, pinch to zoom, two fingers to pan. STL exports the back mesh for CAD/3D-print.")
        }
    }

    // MARK: Derived data

    private struct ProfilePoint: Identifiable {
        let id = UUID()
        let arc: Double
        let value: Double
        var series: String = ""
    }

    private var rockerPoints: [ProfilePoint] {
        result.rocker.map { ProfilePoint(arc: system.length($0.x), value: system.length($0.y)) }
    }

    private var widthPoints: [ProfilePoint] {
        result.metrics
            .filter { $0.isReliable }
            .map { ProfilePoint(arc: system.length($0.arcLength), value: system.length($0.widthAtSpineLevel)) }
    }

    private var treeAnglePoints: [ProfilePoint] {
        var out: [ProfilePoint] = []
        for m in result.metrics {
            if m.angleLeftDegrees.isFinite {
                out.append(ProfilePoint(arc: system.length(m.arcLength), value: m.angleLeftDegrees, series: "Left"))
            }
            if m.angleRightDegrees.isFinite {
                out.append(ProfilePoint(arc: system.length(m.arcLength), value: m.angleRightDegrees, series: "Right"))
            }
        }
        return out
    }
}

/// The cross-section polyline mapped into a view rectangle, preserving aspect
/// ratio, with `v` pointing up.
private struct CrossSectionShape: Shape {
    let points: [SIMD2<Double>]
    let isClosed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let map = CrossSectionMapping(points: points, in: rect)
        path.move(to: map.point(points[0]))
        for p in points.dropFirst() { path.addLine(to: map.point(p)) }
        if isClosed { path.closeSubpath() }
        return path
    }
}

/// Draws the spine origin (u = 0, v = 0) as a red dot in the same mapped frame.
private struct SpineMarker: View {
    let points: [SIMD2<Double>]

    var body: some View {
        GeometryReader { geo in
            let map = CrossSectionMapping(points: points, in: CGRect(origin: .zero, size: geo.size))
            let o = map.point(SIMD2<Double>(0, 0))
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .position(o)
        }
    }
}

/// Shared aspect-preserving mapping from section `(u, v)` metres to view points.
/// Pure value math — nonisolated so it's usable from `Shape.path(in:)`.
private nonisolated struct CrossSectionMapping {
    let minU, minV, spanU, spanV: Double
    let rect: CGRect
    let scale: Double

    init(points: [SIMD2<Double>], in rect: CGRect) {
        let us = points.map(\.x), vs = points.map(\.y)
        minU = us.min() ?? 0
        minV = vs.min() ?? 0
        spanU = max((us.max() ?? 0) - minU, 1e-3)
        spanV = max((vs.max() ?? 0) - minV, 1e-3)
        self.rect = rect
        let inset = 16.0
        scale = min((rect.width - inset) / spanU, (rect.height - inset) / spanV)
    }

    func point(_ p: SIMD2<Double>) -> CGPoint {
        let drawnW = spanU * scale, drawnH = spanV * scale
        let x = (p.x - minU) * scale + (rect.width - drawnW) / 2
        // Flip v (up) to screen space (down).
        let y = rect.height - ((p.y - minV) * scale + (rect.height - drawnH) / 2)
        return CGPoint(x: rect.minX + x, y: rect.minY + y)
    }
}
