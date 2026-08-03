import SwiftUI

/// Shown just before a scan begins, explaining how to conduct it. A checkbox
/// lets the user skip it on future scans (persisted via `@AppStorage`).
struct ScanInstructionsView: View {
    @AppStorage("skipScanInstructions") private var skipInstructions = false
    @Environment(\.dismiss) private var dismiss

    /// Called when the user chooses to begin the scan.
    let onStart: () -> Void

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        .init(icon: "figure.stand", title: "Stand the animal square",
              detail: "All four feet loaded evenly on level ground, standing quietly."),
        .init(icon: "sun.max", title: "Use soft, even light",
              detail: "Indirect light or shade works best; avoid harsh shadows and direct sun."),
        .init(icon: "ruler", title: "Hold 40–80 cm above the back",
              detail: "Keep the phone roughly two hand-widths above the surface."),
        .init(icon: "arrow.left.and.right", title: "Sweep the whole back",
              detail: "Move slowly forward-to-back and side-to-side to cover from withers to tail."),
        .init(icon: "circle.grid.cross", title: "Watch the coverage overlay",
              detail: "Fill in any red or yellow areas until the back reads green."),
        .init(icon: "timer", title: "Keep it short",
              detail: "Aim for under a minute; if the animal shifts a foot, redo the scan."),
    ]

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
                        Text("Start Scan").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
    }
}
