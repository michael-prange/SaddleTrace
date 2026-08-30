import SwiftUI

/// Full-screen front-camera (TrueDepth) capture. Scanning **auto-starts** when the
/// phone is held screen-down over the back and a surface is in range; a live
/// point cloud renders the surface (visible as you reach over the far side).
struct TrueDepthCaptureView: View {
    let animal: AnimalRecord
    let onFinish: (URL?) -> Void
    let onCancel: (URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: TrueDepthCaptureModel
    @State private var controller: TrueDepthCaptureController
    @State private var framesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("truedepth_\(UUID().uuidString)", isDirectory: true)

    init(animal: AnimalRecord, onFinish: @escaping (URL?) -> Void, onCancel: @escaping (URL?) -> Void) {
        self.animal = animal
        self.onFinish = onFinish
        self.onCancel = onCancel
        let model = TrueDepthCaptureModel()
        _model = State(initialValue: model)
        _controller = State(initialValue: TrueDepthCaptureController(model: model))
    }

    var body: some View {
        ZStack {
            if model.isSupported {
                PointCloudSceneView(controller: controller)
                    .ignoresSafeArea()
                    .background(.black)

                HStack {
                    Spacer()
                    DistanceHUD(state: model.state,
                                distanceMeters: model.distanceMeters,
                                nearLimit: model.nearLimit,
                                farLimit: model.farLimit)
                }
                .padding()

                VStack {
                    statusBanner
                    Spacer()
                    if !model.isScanning {
                        Button {
                            controller.requestStart()
                        } label: {
                            Label("Start Scanning", systemImage: "record.circle")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.horizontal)
                    }
                    Button {
                        onFinish(framesDirectory)
                        dismiss()
                    } label: {
                        Text("Finish Scan").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
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
                Image(systemName: "xmark").font(.headline).padding(10)
                    .background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white)
            }
            .padding()
        }
        .statusBarHidden()
        .task { controller.start(framesDirectory: framesDirectory) }
        .onDisappear { controller.stop() }
    }

    private var statusBanner: some View {
        VStack(spacing: 6) {
            if model.isScanning {
                Label("Scanning — \(model.savedFrameCount) frames", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else if !model.isFaceDown {
                Label("Turn the phone screen-down over the back", systemImage: "iphone.gen3.slash")
                    .foregroundStyle(.white)
            } else {
                Label("Move to 25–45 cm to start", systemImage: "arrow.up.and.down")
                    .foregroundStyle(.white)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(.top, 8)
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("No Depth Camera", systemImage: "camera.metering.unknown")
        } description: {
            Text("This device has no TrueDepth front camera.")
        } actions: {
            Button("Close") { onCancel(nil); dismiss() }
        }
    }
}
