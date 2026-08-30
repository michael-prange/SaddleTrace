import Foundation

/// Resolves where the scan store lives: the app's **iCloud Drive** container
/// (so iOS auto-uploads and evicts under storage pressure) when available, else
/// on-device Documents. Resolving touches `url(forUbiquityContainerIdentifier:)`,
/// which must run off the main thread.
nonisolated enum StorageRoot {

    struct Resolved: Sendable {
        /// The `animals/` directory to use as the store root.
        let url: URL
        /// Whether it lives in iCloud Drive.
        let isICloud: Bool
    }

    /// Off-main. Prefers iCloud Drive; migrates any existing local scans into it
    /// the first time iCloud becomes available.
    static func resolve() -> Resolved {
        let fm = FileManager.default
        let localAnimals = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("animals", isDirectory: true)

        guard let ubiquity = fm.url(forUbiquityContainerIdentifier: nil) else {
            return Resolved(url: localAnimals, isICloud: false)
        }

        let iCloudAnimals = ubiquity.appendingPathComponent("Documents/animals", isDirectory: true)
        try? fm.createDirectory(at: iCloudAnimals, withIntermediateDirectories: true)
        migrateLocalScansIfNeeded(from: localAnimals, to: iCloudAnimals)
        return Resolved(url: iCloudAnimals, isICloud: true)
    }

    /// Moves any animal folders still sitting in local Documents into iCloud.
    /// Best-effort, and idempotent.
    ///
    /// Runs on EVERY launch, not just when the iCloud store is empty: each
    /// `setUbiquitous` can fail independently, and gating on "iCloud is still
    /// empty" meant one partial migration stranded the remaining animals in the
    /// local store forever — invisible, because the app now reads from iCloud.
    private static func migrateLocalScansIfNeeded(from local: URL, to iCloud: URL) {
        let fm = FileManager.default
        let localItems = (try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? []
        guard !localItems.isEmpty else { return }

        for item in localItems {
            let destination = iCloud.appendingPathComponent(item.lastPathComponent)
            // Never clobber an animal that already made it across.
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.setUbiquitous(true, itemAt: item, destinationURL: destination)
        }
    }
}
