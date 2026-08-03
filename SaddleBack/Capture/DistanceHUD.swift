import SwiftUI

/// Vertical gauge showing whether the phone is too close / just right / too far,
/// with a moving indicator and the live distance in the user's units.
struct DistanceHUD: View {
    let state: CaptureDistanceState
    let distanceMeters: Double?
    let nearLimit: Double
    let farLimit: Double

    @AppStorage("measurementSystem") private var systemRaw = MeasurementSystem.metric.rawValue
    private var system: MeasurementSystem { MeasurementSystem(rawValue: systemRaw) ?? .metric }

    // Gauge spans this distance range (metres), with the ideal band centred.
    private let gaugeMin = 0.20
    private let gaugeMax = 1.00

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.headline)
                .foregroundStyle(color)
            Text(distanceText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white)

            gauge
                .frame(width: 26, height: 220)
        }
        .padding(12)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Maps a distance (metres) to a y-offset in a track of height `h`, with the
    /// far end at the top and the near end at the bottom.
    private func y(for d: Double, in h: CGFloat) -> CGFloat {
        let t = (d - gaugeMin) / (gaugeMax - gaugeMin)
        return h * (1 - CGFloat(min(max(t, 0), 1)))
    }

    private var gauge: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let bandTop = y(for: farLimit, in: h)
            let bandBottom = y(for: nearLimit, in: h)

            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.15))
                // Ideal band.
                Capsule()
                    .fill(.green.opacity(0.6))
                    .frame(height: max(bandBottom - bandTop, 2))
                    .offset(y: bandTop)
                // Current-distance indicator.
                if let d = distanceMeters {
                    Capsule()
                        .fill(color)
                        .frame(height: 4)
                        .overlay(Capsule().stroke(.white, lineWidth: 1))
                        .offset(y: y(for: d, in: h) - 2)
                }
            }
        }
    }

    private var label: String {
        switch state {
        case .noSurface: "Aim at the back"
        case .tooClose: "Too close"
        case .justRight: "Just right"
        case .tooFar: "Too far"
        }
    }

    private var color: Color {
        switch state {
        case .noSurface: .gray
        case .tooClose, .tooFar: .orange
        case .justRight: .green
        }
    }

    private var distanceText: String {
        guard let d = distanceMeters else { return "—" }
        return system.lengthString(d)
    }
}
