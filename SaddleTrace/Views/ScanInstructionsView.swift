import SwiftUI

/// Shown just before a scan begins, explaining how to conduct it. A checkbox
/// lets the user skip it on future scans (persisted via `@AppStorage`).
struct ScanInstructionsView: View {
    @AppStorage("skipScanInstructions") private var skipInstructions = false
    @AppStorage("measurementSystem") private var systemRaw = MeasurementSystem.metric.rawValue
    @Environment(\.dismiss) private var dismiss

    /// Called when the user chooses to begin the scan.
    let onStart: () -> Void

    private var imperial: Bool { MeasurementSystem(rawValue: systemRaw) == .imperial }

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private var steps: [Step] {
        let region = imperial ? "about 20 in" : "about 50 cm"
        let height = imperial ? "about 20–24 in" : "about 50–60 cm"
        return [
            .init(icon: "figure.stand", title: "Stand the animal square",
                  detail: "All four feet loaded evenly on level ground, standing quietly."),
            .init(icon: "sun.max", title: "Use soft, even light",
                  detail: "Indirect light or shade works best; avoid harsh shadows and direct sun."),
            .init(icon: "viewfinder.rectangular", title: "Frame the saddle area",
                  detail: "Fill the on-screen box with \(region) of back — the part the saddle rests on. Center the spine in the box."),
            .init(icon: "arrow.up.and.down", title: "Hold \(height) above",
                  detail: "Roughly arm's length above the back. You can hold lower and angle the phone forward so you can see the screen."),
            .init(icon: "camera.aperture", title: "Hold still and tap once",
                  detail: "It's a single shot — no sweeping. When the distance reads good, hold steady and tap Capture."),
            .init(icon: "checkmark.circle", title: "Check, then keep or retake",
                  detail: "Review the shot; retake if the back isn't fully in the box. If the animal shifts a foot, retake."),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: step.icon)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.headline)
                                Text(step.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Before You Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Toggle("Don't show this again", isOn: $skipInstructions)
                    Button {
                        dismiss()
                        onStart()
                    } label: {
                        Text("OK").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
    }
}
