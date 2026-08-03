import Foundation
import MeshKit

/// CSV exporters for cross-section geometry and per-station metrics (Design §11).
/// Lengths are emitted in centimetres, symmetry error in millimetres, angles in
/// degrees — matching the column names.
public enum CSVWriter {

    private static let mToCm = 100.0
    private static let mToMm = 1000.0

    /// `station_index, arc_length_cm, point_index, u_cm, v_cm` — one row per
    /// polyline vertex across all sections.
    public static func sectionsCSV(_ sections: [CrossSection]) -> String {
        var out = "station_index,arc_length_cm,point_index,u_cm,v_cm\n"
        for section in sections {
            let arcCm = fmt(section.arcLength * mToCm)
            for (i, p) in section.points2D.enumerated() {
                out += "\(section.stationIndex),\(arcCm),\(i),\(fmt(p.x * mToCm)),\(fmt(p.y * mToCm))\n"
            }
        }
        return out
    }

    /// `station_index, arc_length_cm, width_cm, angle_left_deg, angle_right_deg,
    /// symmetry_rms_mm` — one row per station.
    public static func metricsCSV(_ metrics: [SectionMetrics]) -> String {
        var out = "station_index,arc_length_cm,width_cm,angle_left_deg,angle_right_deg,symmetry_rms_mm,reliable\n"
        for m in metrics {
            out += "\(m.stationIndex),\(fmt(m.arcLength * mToCm)),\(fmt(m.widthAtSpineLevel * mToCm)),"
            out += "\(fmt(m.angleLeftDegrees)),\(fmt(m.angleRightDegrees)),\(fmt(m.symmetricErrorRMS * mToMm)),"
            out += "\(m.isReliable ? 1 : 0)\n"
        }
        return out
    }

    public static func write(sections: [CrossSection], to url: URL) throws {
        try sectionsCSV(sections).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func write(metrics: [SectionMetrics], to url: URL) throws {
        try metricsCSV(metrics).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Fixed-point formatting (locale-independent, no scientific notation).
    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
