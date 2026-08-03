import SwiftUI

/// Shows a scan's status and, once processed, its landmarks, per-station metrics,
/// and a share sheet for the exported files. Until capture/reconstruction exist,
/// "Process" runs the pipeline on a synthetic back mesh.
struct ScanDetailView: View {
    let animal: AnimalRecord
    @State var scan: ScanRecord
    @Environment(AppModel.self) private var appModel

    @State private var isProcessing = false
    @State private var isLoading = false
    @State private var result: ProcessedScan?

    var body: some View {
        Group {
            if let result {
                ResultView(result: result)
            } else if isLoading {
                ProgressView("Loading results…")
            } else {
                List {
                    Section("Scan") {
                        LabeledContent("Captured", value: scan.timestamp.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Mode", value: scan.captureMode.displayName)
                        LabeledContent("Detail", value: scan.detail.rawValue.capitalized)
                        LabeledContent("Status", value: scan.status.displayName)
                        if let processed = scan.processingSummary {
                            LabeledContent("Processing time", value: processed)
                        }
                    }
                    processingSection
                }
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIfComplete() }
    }

    /// When opening an already-completed scan, reload its results (fast MeshKit
    /// pipeline over the saved mesh) so they display without re-reconstructing.
    private func loadIfComplete() async {
        guard result == nil, !isProcessing, scan.status == .complete else { return }
        isLoading = true
        result = await appModel.loadResult(for: scan, animalID: animal.id)
        isLoading = false
    }

    private var hasFrames: Bool {
        appModel.hasCapturedFrames(animalID: animal.id, scanID: scan.id)
    }

    @ViewBuilder
    private var processingSection: some View {
        if let progress = appModel.reconstructionProgress {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reconstructing…").font(.headline)
                    ProgressView(value: progress)
                    Text("This can take a few minutes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if hasFrames && appModel.canReconstruct {
            Section {
                Button { reconstruct() } label: {
                    if isProcessing { HStack { ProgressView(); Text("Working…") } }
                    else { Label("Reconstruct Scan", systemImage: "cube.transparent") }
                }
                .disabled(isProcessing)
            } footer: {
                Text("Builds a 3D mesh from the captured frames, then extracts the saddle geometry.")
            }
        } else {
            Section {
                Button { process() } label: {
                    if isProcessing { HStack { ProgressView(); Text("Processing…") } }
                    else { Label("Process Demo Mesh", systemImage: "gearshape.2") }
                }
                .disabled(isProcessing)
            } footer: {
                Text(appModel.canReconstruct
                     ? "No captured frames for this scan — runs the pipeline on a synthetic back mesh."
                     : "This device can't reconstruct — runs the pipeline on a synthetic back mesh.")
            }
        }
    }

    private func process() {
        isProcessing = true
        Task {
            let outcome = await appModel.processScan(scan, for: animal.id)
            result = outcome
            scan.status = outcome != nil ? .complete : .failed
            isProcessing = false
        }
    }

    private func reconstruct() {
        isProcessing = true
        Task {
            let outcome = await appModel.reconstructScan(scan, for: animal.id)
            result = outcome
            scan.status = outcome != nil ? .complete : .failed
            isProcessing = false
        }
    }
}
