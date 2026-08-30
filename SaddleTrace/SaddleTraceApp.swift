//
//  SaddleTraceApp.swift
//  SaddleTrace
//
//  Created by Michael Prange on 7/30/26.
//

import SwiftUI

@main
struct SaddleTraceApp: App {
    @State private var appModel: AppModel?
    /// An archive opened via "Open With…" before the model finished loading.
    @State private var pendingImport: URL?

    var body: some Scene {
        WindowGroup {
            Group {
                if let appModel {
                    AnimalListView()
                        .environment(appModel)
                } else {
                    ProgressView("Preparing…")
                        .task {
                            let model = await AppModel.make()
                            await model.loadAnimals()
                            appModel = model
                            if let url = pendingImport {
                                pendingImport = nil
                                await importArchive(url, into: model)
                            }
                        }
                }
            }
            .onOpenURL { url in
                // A `.saddletrace` archive opened from Files / share sheet / AirDrop.
                if let appModel {
                    Task { await importArchive(url, into: appModel) }
                } else {
                    pendingImport = url   // model still loading; import once it's ready
                }
            }
        }
    }

    private func importArchive(_ url: URL, into model: AppModel) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        _ = await model.importArchive(from: url)
    }
}
