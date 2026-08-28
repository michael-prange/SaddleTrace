import SwiftUI
import UniformTypeIdentifiers

/// Root view: the animal roster. Tapping an animal drills into its scan history.
struct AnimalListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingImporter = false
    @State private var shareItem: ShareItem?
    @State private var isBuilding = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(appModel.animals) { animal in
                    NavigationLink(value: animal) {
                        AnimalRow(animal: animal)
                    }
                }
                .onDelete(perform: deleteAnimals)
            }
            .navigationTitle("Animals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Animal", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import Scans…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            shareAll()
                        } label: {
                            Label("Share All Scans…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(appModel.animals.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: AnimalRecord.self) { animal in
                ScanListView(animal: animal)
            }
            .sheet(isPresented: $showingAdd) {
                AddAnimalView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { performImport(url) }
            }
            .overlay {
                if isBuilding {
                    ProgressView("Working…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if appModel.animals.isEmpty {
                    ContentUnavailableView(
                        "No Animals",
                        systemImage: "hare",
                        description: Text("Add an animal to begin scanning its back.")
                    )
                }
            }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private func deleteAnimals(_ offsets: IndexSet) {
        let ids = offsets.map { appModel.animals[$0].id }
        Task { for id in ids { await appModel.deleteAnimal(id) } }
    }

    private func shareAll() {
        isBuilding = true
        Task {
            let url = await appModel.exportAllArchive()
            isBuilding = false
            if let url { shareItem = ShareItem(url: url) }
        }
    }

    private func performImport(_ url: URL) {
        isBuilding = true
        Task {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let count = await appModel.importArchive(from: url)
            isBuilding = false
            importMessage = count > 0 ? "Imported \(count) scan\(count == 1 ? "" : "s")." : "No scans were imported."
        }
    }
}

private struct AnimalRow: View {
    let animal: AnimalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(animal.name).font(.headline)
            Text(animal.species.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
