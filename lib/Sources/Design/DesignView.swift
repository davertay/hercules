import Chat
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct DesignView: View {
    @Bindable var model: DesignModel

    public init(model: DesignModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isIntake {
                IntakeView()
            } else {
                ChatTranscript(engine: model.engine)
            }
            if let savedURL = model.summarySavedURL {
                Divider()
                DesignSummarySavedBanner(url: savedURL)
            }
            Divider()
            ChatComposer(engine: model.engine)
        }
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            if model.isGenerateSummaryAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Generate Design Summary", systemImage: "doc.text") {
                        model.generateSummary()
                    }
                    .disabled(model.engine.isRunning)
                }
            }
        }
    }
}

private struct IntakeView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("What are we building today?")
                .font(.title)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Confirmation that the Design summary was saved, with a Reveal in Finder button. The user edits
/// the markdown externally; the app never renders or edits it in place.
private struct DesignSummarySavedBanner: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Design summary saved")
                    .font(.callout.weight(.medium))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
