import SwiftUI

/// Root view: the animal roster. Tapping an animal drills into its scan history.
struct AnimalListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingAdd = false
    @State private var showingSettings = false

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
            .overlay {
                if appModel.animals.isEmpty {
                    ContentUnavailableView(
                        "No Animals",
                        systemImage: "hare",
                        description: Text("Add an animal to begin scanning its back.")
                    )
                }
            }
        }
    }

    private func deleteAnimals(_ offsets: IndexSet) {
        let ids = offsets.map { appModel.animals[$0].id }
        Task { for id in ids { await appModel.deleteAnimal(id) } }
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
