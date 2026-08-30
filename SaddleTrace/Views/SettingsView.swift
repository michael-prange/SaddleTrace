import SwiftUI
import ExportKit

/// App settings. Currently just the measurement-system choice.
struct SettingsView: View {
    @AppStorage("measurementSystem") private var systemRaw = MeasurementSystem.metric.rawValue
    @AppStorage("stationSpacingMeters") private var stationSpacing = 0.1016
    @AppStorage("reconstructionDetail") private var detailRaw = ReconstructionDetail.reduced.rawValue
    @AppStorage("captureCamera") private var cameraRaw = CaptureCameraPreference.auto.rawValue
    @AppStorage("pdfPageSize") private var pdfPageSizeRaw = PDFPageSize.letter.rawValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private var system: MeasurementSystem { MeasurementSystem(rawValue: systemRaw) ?? .metric }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Measurement System", selection: $systemRaw) {
                        ForEach(MeasurementSystem.allCases) { system in
                            Text(system.displayName).tag(system.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Affects on-screen values only. Exported DXF and CSV files stay in centimetres.")
                }

                Section {
                    Stepper(value: $stationSpacing,
                            in: 0.02...0.30,
                            step: system == .metric ? 0.005 : 0.0127) {
                        LabeledContent("Spacing",
                                       value: system.lengthString(stationSpacing,
                                                                  fractionDigits: system == .metric ? 1 : 2))
                    }
                } header: {
                    Text("Cross-section spacing")
                } footer: {
                    Text("Sections are taken starting at the top of the withers and stepping toward the tail by this spacing.")
                }

                Section {
                    Picker("Camera", selection: $cameraRaw) {
                        ForEach(CaptureCameraPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref.rawValue)
                        }
                    }
                } header: {
                    Text("Scanning camera")
                } footer: {
                    Text("Automatic uses the rear LiDAR on Pro iPhones and the front TrueDepth camera otherwise. The front camera auto-starts when you hold the phone screen-down over the back.")
                }

                Section {
                    Picker("Detail", selection: $detailRaw) {
                        Text("Reduced").tag(ReconstructionDetail.reduced.rawValue)
                        Text("Medium").tag(ReconstructionDetail.medium.rawValue)
                        Text("Raw (maximum)").tag(ReconstructionDetail.raw.rawValue)
                    }
                } header: {
                    Text("Reconstruction detail")
                } footer: {
                    Text("Quality of the reconstructed mesh — independent of how long you scan. Higher detail gives more resolution but takes longer to process and heats the phone. Reduced is ample for saddle geometry; capture good coverage from many angles for best results.")
                }

                Section {
                    Picker("PDF page size", selection: $pdfPageSizeRaw) {
                        ForEach(PDFPageSize.allCases, id: \.rawValue) { size in
                            Text(size.displayName).tag(size.rawValue)
                        }
                    }
                } header: {
                    Text("Cross-section PDF")
                } footer: {
                    Text("Page size for the cross-section report (drawn landscape). Your fitter's 11×17 is \"Tabloid\".")
                }

                Section {
                    LabeledContent("Scans stored in",
                                   value: appModel.isUsingICloud ? "iCloud Drive" : "On this iPhone")
                } header: {
                    Text("Storage")
                } footer: {
                    Text(appModel.isUsingICloud
                         ? "Scans sync to iCloud Drive; iOS frees local space automatically when storage is low and re-downloads on demand."
                         : "iCloud isn't enabled, so scans are kept on this iPhone only. Turn on iCloud Drive in Settings to offload older scans automatically.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
