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
    @State private var showingCloud = false
    @AppStorage("measurementSystem") private var systemRaw = MeasurementSystem.metric.rawValue

    private var system: MeasurementSystem { MeasurementSystem(rawValue: systemRaw) ?? .metric }

    /// Spine arc length of the withers (station 0). All "distance along the back"
    /// values are shown relative to this, so the withers reads 0.
    private var withersArc: Double { result.spine.withersArcLength }

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
            if let painted = result.exports.paintedSurfaceURL {
                PaintedSurface3DView(url: painted, tracingsURL: result.exports.tracingsURL)
            } else if let url = result.exports.viewableModelURL {
                Model3DView(url: url)
            }
        }
        .sheet(isPresented: $showingCloud) {
            if let url = result.exports.pointCloudURL {
                PointCloud3DView(url: url, tracingsURL: result.exports.tracingsURL)
            }
        }
        .onAppear {
            // Start at the withers (Section 0).
            stationIndex = 0
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
                Text("Section \(section.stationIndex) · \(system.lengthString(abs(section.arcLength - withersArc))) from withers")
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

    private var alongLabel: String { "From withers (\(system.lengthUnit))" }

    private var rockerSection: some View {
        Section("Topline (rocker)") {
            Chart(rockerPoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Height (\(system.lengthUnit))", p.value))
            }
            .chartXAxisLabel(alongLabel)
            .chartYAxisLabel("Height (\(system.lengthUnit))")
            .frame(height: 160)
        }
    }

    private var widthSection: some View {
        Section {
            Chart(widthPoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Width (\(system.lengthUnit))", p.value))
            }
            .chartXAxisLabel(alongLabel)
            .chartYAxisLabel("Width (\(system.lengthUnit))")
            .frame(height: 160)
        } header: {
            HStack {
                Text("Width below spine")
                Spacer()
                MetricInfoButton(
                    title: "Width below spine",
                    message: "For each cross-section, how wide the back is 5 cm below the top of the spine. The horizontal axis is distance from the withers (0), stepping toward the tail.")
            }
        }
    }

    private var treeAngleSection: some View {
        Section {
            Chart(treeAnglePoints) { p in
                LineMark(x: .value(alongLabel, p.arc), y: .value("Angle (°)", p.value))
                    .foregroundStyle(by: .value("Side", p.series))
            }
            .chartForegroundStyleScale(["Left": Color.blue, "Right": Color.orange])
            .chartXAxisLabel(alongLabel)
            .chartYAxisLabel("Angle (°)")
            .frame(height: 160)
        } header: {
            HStack {
                Text("Tree angles")
                Spacer()
                MetricInfoButton(
                    title: "Tree angles",
                    message: "The slope of the back's surface just off the spine — measured 5 cm out on each side and reported as degrees below horizontal. This is the angle a saddle tree's panels must match. Left and right are measured separately. Distance along the back is measured from the withers (0).")
            }
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
            if result.exports.pointCloudURL != nil {
                Button {
                    showingCloud = true
                } label: {
                    Label("View Point Cloud", systemImage: "aqi.medium")
                }
            }
            if let pdf = result.exports.reportPDF {
                ShareLink(item: pdf) {
                    Label("Share Cross-Section PDF", systemImage: "doc.richtext")
                }
            }
            ShareLink(items: result.exports.shareables) {
                Label("Share All Exports (PDF · PLY · STL · DXF · CSV)", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Drag to rotate, pinch to zoom, two fingers to pan. STL exports the back mesh for CAD/3D-print.")
        }
    }

    // MARK: Derived data

    private struct ProfilePoint: Identifiable {
        let arc: Double
        let value: Double
        var series: String = ""
        /// Derived, not a fresh UUID: these are recomputed on every render, so a
        /// new identity each time defeated Charts' diffing.
        var id: String { "\(series)-\(arc)" }
    }

    private var rockerPoints: [ProfilePoint] {
        result.rocker.map { ProfilePoint(arc: system.length(abs($0.x - withersArc)), value: system.length($0.y)) }
    }

    private var widthPoints: [ProfilePoint] {
        result.metrics
            .filter { $0.isReliable }
            .map { ProfilePoint(arc: system.length(abs($0.arcLength - withersArc)), value: system.length($0.widthBelowSpine)) }
    }

    private var treeAnglePoints: [ProfilePoint] {
        var out: [ProfilePoint] = []
        for m in result.metrics {
            let arc = system.length(abs(m.arcLength - withersArc))
            if m.angleLeftDegrees.isFinite {
                out.append(ProfilePoint(arc: arc, value: m.angleLeftDegrees, series: "Left"))
            }
            if m.angleRightDegrees.isFinite {
                out.append(ProfilePoint(arc: arc, value: m.angleRightDegrees, series: "Right"))
            }
        }
        return out
    }
}

/// A small info button that reveals a short explanation in a popover. Used on the
/// Width and Tree-angle plots to explain how those metrics are measured.
private struct MetricInfoButton: View {
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
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
