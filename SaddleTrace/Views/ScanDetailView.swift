import SwiftUI

/// Shows a scan's status and, once processed, its landmarks, per-station metrics,
/// and a share sheet for the exported files.
struct ScanDetailView: View {
    let animal: AnimalRecord
    @State var scan: ScanRecord
    @Environment(AppModel.self) private var appModel

    @State private var isProcessing = false
    @State private var isLoading = false
    @State private var result: ProcessedScan?
    @State private var shareItem: ShareItem?
    @State private var isBuilding = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { shareScan() } label: {
                    Label("Share Scan", systemImage: "square.and.arrow.up")
                }
                .disabled(isBuilding)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .overlay {
            if isBuilding {
                ProgressView("Preparing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await loadIfComplete() }
    }

    private func shareScan() {
        isBuilding = true
        Task {
            let url = await appModel.exportScanArchive(animalID: animal.id, scanID: scan.id)
            isBuilding = false
            if let url { shareItem = ShareItem(url: url) }
        }
    }

    /// When opening an already-completed scan, reload its results (fast MeshKit
    /// pipeline over the saved mesh) so they display without re-reconstructing.
    private func loadIfComplete() async {
        guard result == nil, !isProcessing, scan.status == .complete else { return }
        isLoading = true
        result = await appModel.loadResult(for: scan, animalID: animal.id)
        isLoading = false
    }

    /// Whether *this* scan has something on disk to reconstruct from — a LiDAR
    /// mesh or captured frames. Shares `AppModel`'s test with the auto-reconstruct
    /// queue so the button and the queue can't disagree.
    private var canReconstructThis: Bool {
        appModel.reconstructionInput(animalID: animal.id, scanID: scan.id) != nil
    }

    @ViewBuilder
    private var processingSection: some View {
        // Only this scan's own progress — the queue is shared, so a different
        // scan reconstructing used to show up here as if it were this one.
        if let progress = appModel.reconstruction, progress.scanID == scan.id {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reconstructing…").font(.headline)
                    ProgressView(value: progress.fraction)
                    Text("This can take a few minutes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if canReconstructThis {
            Section {
                Button { reconstruct() } label: {
                    if isProcessing { HStack { ProgressView(); Text("Working…") } }
                    else { Label("Reconstruct Scan", systemImage: "cube.transparent") }
                }
                .disabled(isProcessing)
            } footer: {
                Text("Builds a 3D mesh from the captured shot, then extracts the saddle geometry.")
            }
        } else {
            Section {
                Text("No captured data for this scan.")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Take a new scan — capture a single LiDAR shot of the saddle area.")
            }
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
