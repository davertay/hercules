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
            if model.isSkipped {
                PRDSkippedView(unskip: model.unskip)
            } else if model.isIdle {
                IdleActionView(isGenerateAvailable: model.isGenerateAvailable, generate: model.generate, skip: model.skip)
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
                    Button("Generate PRD from Design Summary", systemImage: "text.document") {
                        model.generate()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Skip", systemImage: "chevron.right.2") {
                        model.skip()
                    }
                }
            }
        }
    }
}
