import Foundation

/// User-selectable display units. Persisted via `@AppStorage("measurementSystem")`.
/// This affects on-screen presentation only; exported DXF/CSV stay in centimetres
/// (CAD convention, and the CSV columns are named `_cm`).
nonisolated enum MeasurementSystem: String, CaseIterable, Sendable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .metric: "Metric (cm)"
        case .imperial: "Imperial (in)"
        }
    }

    /// Unit label for lengths.
    var lengthUnit: String { self == .metric ? "cm" : "in" }

    private static let metresToInches = 39.3700787

    /// Converts metres to the display unit's numeric value (cm or inches).
    func length(_ metres: Double) -> Double {
        self == .metric ? metres * 100 : metres * Self.metresToInches
    }

    /// Formats a length in metres for display, e.g. `"149.0 cm"` or `"58.7 in"`.
    func lengthString(_ metres: Double, fractionDigits: Int = 1) -> String {
        String(format: "%.\(fractionDigits)f %@", length(metres), lengthUnit)
    }

    /// Formats a small length (e.g. symmetry error) — millimetres in metric,
    /// inches in imperial.
    func smallLengthString(_ metres: Double) -> String {
        self == .metric
            ? String(format: "%.1f mm", metres * 1000)
            : String(format: "%.3f in", metres * Self.metresToInches)
    }
}
