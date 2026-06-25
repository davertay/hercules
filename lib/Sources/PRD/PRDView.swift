import Chat
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// The PRD Phase surface: a directed one-shot with no composer. Idle shows the generate action; a run
/// shows the streaming Transcript; done adds a saved confirmation.
public struct PRDView: View {
    @Bindable var model: PRDModel

    public init(model: PRDModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isIdle {
                IdleActionView(isGenerateAvailable: model.isGenerateAvailable) {
                    model.generate()
                }
            } else {
                ChatTranscript(engine: model.engine)
            }
            if let savedURL = model.prdSavedURL {
                Divider()
                PRDSavedBanner(url: savedURL, isRegenerateAvailable: model.isRegenerateAvailable) {
                    model.regenerate()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            // Kept reachable so an errored run can be retried; gone once the Phase completes.
            if !model.isIdle && model.isGenerateAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Generate PRD from Design Summary", systemImage: "doc.text") {
                        model.generate()
                    }
                }
            }
        }
    }
}

private struct IdleActionView: View {
    let isGenerateAvailable: Bool
    let generate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Turn the Design summary into a PRD grounded in the repo.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Generate PRD from Design Summary", systemImage: "doc.text") {
                generate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isGenerateAvailable)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The user edits the markdown externally; the app never renders or edits it in place.
private struct PRDSavedBanner: View {
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
