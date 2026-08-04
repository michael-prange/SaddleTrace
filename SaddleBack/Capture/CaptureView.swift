import SwiftUI

/// Full-screen live capture: the reconstructed mesh builds on screen in bold
/// coverage colors while the distance HUD and coverage meter guide the operator.
/// Frames are written to a temp directory; `onFinish` promotes them into a scan,
/// `onCancel` discards them.
struct CaptureView: View {
    let animal: AnimalRecord
    /// Called with the temp frames directory when the user finishes (nil = demo).
    let onFinish: (URL?) -> Void
    /// Called with the temp frames directory when the user cancels (nil = demo).
    let onCancel: (URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = CaptureModel()
    @State private var framesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture_\(UUID().uuidString)", isDirectory: true)
    @State private var finishing = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            if model.isSupported {
                ARCaptureView(model: model, framesDirectory: framesDirectory)
                    .ignoresSafeArea()

                HStack {
                    Spacer()
                    DistanceHUD(state: model.state,
                                distanceMeters: model.distanceMeters,
                                nearLimit: model.nearLimit,
                                farLimit: model.farLimit)
                }
                .padding()

                VStack {
                    coverageBar
                    if !model.isTrackingNormal {
                        Text("Move slowly to build tracking…")
                            .font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                    }
                    Spacer()
                    Button {
                        beginFinish()
                    } label: {
                        Group {
                            if finishing {
                                HStack { ProgressView().tint(.white); Text("Finishing…") }
                            } else {
                                Text("Finish Scan")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(finishing)
                    .padding()
                }
            } else {
                unsupported
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                onCancel(model.isSupported ? framesDirectory : nil)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding()
        }
        .statusBarHidden()
        .onChange(of: model.meshExportFinished) { completeFinish() }
    }

    /// Ask the AR coordinator to write the fused LiDAR mesh, then finish. Falls
    /// back to finishing anyway if no frame arrives to export within a moment.
    private func beginFinish() {
        guard !finishing else { return }
        finishing = true
        model.requestMeshExport?(framesDirectory.appendingPathComponent("lidar.obj"))
        Task {
            try? await Task.sleep(for: .seconds(3))
            completeFinish()
        }
    }

    private func completeFinish() {
        guard finishing, !didFinish else { return }
        didFinish = true
        onFinish(framesDirectory)
        dismiss()
    }

    private var coverageBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Coverage \(Int(model.coverageFraction * 100))%")
                Spacer()
                Text("\(model.savedFrameCount) frames")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            ProgressView(value: model.coverageFraction)
                .tint(.green)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("LiDAR Required", systemImage: "camera.metering.unknown")
        } description: {
            Text("Live scanning needs a Pro iPhone with a LiDAR scanner.")
        } actions: {
            Button("Use Demo Scan") {
                onFinish(nil)
                dismiss()
            }
            Button("Close") {
                onCancel(nil)
                dismiss()
            }
        }
    }
}
