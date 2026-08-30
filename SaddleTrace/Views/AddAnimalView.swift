import SwiftUI

/// Form for creating a new animal record.
struct AddAnimalView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var species: Species = .horse
    @State private var hasDateOfBirth = false
    @State private var dateOfBirth = Date.now
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Species", selection: $species) {
                        ForEach(Species.allCases) { species in
                            Text(species.displayName).tag(species)
                        }
                    }
                }
                Section {
                    Toggle("Date of Birth", isOn: $hasDateOfBirth.animation())
                    if hasDateOfBirth {
                        DatePicker("Born", selection: $dateOfBirth, displayedComponents: .date)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .navigationTitle("New Animal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            await appModel.addAnimal(
                name: trimmed, species: species,
                dateOfBirth: hasDateOfBirth ? dateOfBirth : nil, notes: notes
            )
            dismiss()
        }
    }
}
