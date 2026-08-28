import SwiftUI
import UIKit

/// Identifiable wrapper so a produced file URL can drive `.sheet(item:)`.
struct ShareItem: Identifiable { let id = UUID(); let url: URL }

/// UIKit share sheet for programmatically-produced files (e.g. a scan archive
/// built on demand), where `ShareLink` can't be used because the URL isn't known
/// until a button is tapped.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
