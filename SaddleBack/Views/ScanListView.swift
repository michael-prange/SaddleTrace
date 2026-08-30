import SwiftUI

/// An animal's scan history. "New Scan" runs the capture flow for the resolved
/// mode (rear single-shot LiDAR, else front TrueDepth), then auto-reconstructs.
struct ScanListView: View {
    let animal: AnimalRecord
    @Environment(AppModel.self) private var appModel
    @AppStorage("stationSpacingMeters") private var stationSpacing = 0.1016
    @AppStorage("reconstructionDetail") private var detailRaw = ReconstructionDetail.reduced.rawValue
    @AppStorage("captureCamera") private var cameraRaw = CaptureCameraPreference.auto.rawValue
    @AppStorage("skipScanInstructions") private var skipInstructions = false
    @State private var scans: [ScanRecord] = []
    @State private var showingInstructions = false
    @State private var showingCapture = false

    var body: some View {
        List {
            ForEach(scans) { scan in
                NavigationLink(value: scan) {
                    ScanRow(scan: scan)
                }
            }
            .onDelete(perform: deleteScans)
        }
        .navigationTitle(animal.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ScanRecord.self) { scan in
            ScanDetailView(animal: animal, scan: scan)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if skipInstructions { showingCapture = true } else { showingInstructions = true }
                } label: {
                    Label("New Scan", systemImage: "camera.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showingInstructions) {
            ScanInstructionsView {
                // Present the capture screen after the sheet dismisses.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    showingCapture = true
                }
            }
        }
        .fullScreenCover(isPresented: $showingCapture) {
            let mode = CaptureCapabilities.resolvedMode(
                preference: CaptureCameraPreference(rawValue: cameraRaw) ?? .auto) ?? .trueDepth
            Group {
                if mode == .trueDepth {
                    TrueDepthCaptureView(animal: animal,
                                         onFinish: { finishCapture(mode: .trueDepth, tempFrames: $0) },
                                         onCancel: { cancelCapture(tempFrames: $0) })
                } else {
                    // Rear LiDAR: single-shot depth capture (replaces the sweep,
                    // which drifted/fragmented). CaptureView remains for reference.
                    LiDARShotCaptureView(animal: animal,
                                         onFinish: { finishCapture(mode: .lidar, tempFrames: $0) },
                                         onCancel: { cancelCapture(tempFrames: $0) })
                }
            }
        }
        .overlay {
            if scans.isEmpty {
                ContentUnavailableView(
                    "No Scans",
                    systemImage: "camera.viewfinder",
                    description: Text("Start a new scan to capture this animal's back.")
                )
            }
        }
        .task { await reload() }
        .onChange(of: appModel.reconstruction == nil) {
            // Refresh when a reconstruction starts or finishes so the row's status
            // (Reconstructing… → Complete/Failed) stays current.
            Task { await reload() }
        }
    }

    private func reload() async {
        scans = await appModel.scans(for: animal.id)
    }

    private func finishCapture(mode: CaptureMode, tempFrames: URL?) {
        let detail = ReconstructionDetail(rawValue: detailRaw) ?? .reduced
        Task {
            guard let scan = await appModel.finishCapture(
                for: animal.id, mode: mode, detail: detail,
                stationSpacingMeters: stationSpacing, tempFramesDirectory: tempFrames) else { return }
            await reload()
            // Kick off reconstruction automatically; it runs (serialized) and the
            // list refreshes to show "Reconstructing…" and then the result.
            await appModel.autoReconstruct(scan, for: animal.id)
            await reload()
        }
    }

    private func cancelCapture(tempFrames: URL?) {
        if let tempFrames { try? FileManager.default.removeItem(at: tempFrames) }
    }

    private func deleteScans(_ offsets: IndexSet) {
        let ids = offsets.map { scans[$0].id }
        Task {
            for id in ids { await appModel.delete(scan: id, from: animal.id) }
            await reload()
        }
    }
}

private struct ScanRow: View {
    let scan: ScanRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scan.timestamp, format: .dateTime.day().month().year().hour().minute())
                .font(.headline)
            HStack(spacing: 6) {
                Text(scan.captureMode.displayName)
                Text("·")
                Text(scan.status.displayName)
                if let processed = scan.processingSummary {
                    Text("·")
                    Text("processed in \(processed)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
