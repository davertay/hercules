import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The user edits the markdown externally; the app never renders or edits it in place.
struct PRDSavedBanner: View {
    let url: URL
    let isRegenerateAvailable: Bool
    let regenerate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("PRD saved")
                    .font(.callout.weight(.medium))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Regenerate", systemImage: "arrow.clockwise") {
                regenerate()
            }
            .disabled(!isRegenerateAvailable)
            #if canImport(AppKit)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
