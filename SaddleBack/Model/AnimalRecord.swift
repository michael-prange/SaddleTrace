import Foundation

/// The species of the scanned animal. Deliberately broad — Michael's herd
/// includes horses, a mule, and llamas (Design M-5).
nonisolated enum Species: String, Codable, CaseIterable, Sendable, Identifiable {
    case horse, mule, donkey, pony, llama, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horse: "Horse"
        case .mule: "Mule"
        case .donkey: "Donkey"
        case .pony: "Pony"
        case .llama: "Llama"
        case .other: "Other"
        }
    }
}

/// A scanned animal's identity. Persisted as `animals/{id}/info.json` (Design §10).
nonisolated struct AnimalRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var species: Species
    var dateOfBirth: Date?
    var notes: String

    init(id: UUID = UUID(), name: String, species: Species,
         dateOfBirth: Date? = nil, notes: String = "") {
        self.id = id
        self.name = name
        self.species = species
        self.dateOfBirth = dateOfBirth
        self.notes = notes
    }
}
