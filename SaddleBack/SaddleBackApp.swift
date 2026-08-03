//
//  SaddleBackApp.swift
//  SaddleBack
//
//  Created by Michael Prange on 7/30/26.
//

import SwiftUI

@main
struct SaddleBackApp: App {
    @State private var appModel: AppModel?

    var body: some Scene {
        WindowGroup {
            if let appModel {
                AnimalListView()
                    .environment(appModel)
            } else {
                ProgressView("Preparing…")
                    .task {
                        let model = await AppModel.make()
                        await model.loadAnimals()
                        appModel = model
                    }
            }
        }
    }
}
