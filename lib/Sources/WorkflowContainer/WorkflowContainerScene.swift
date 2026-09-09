import SwiftUI

public struct WorkflowContainerScene: Scene {
    private let registry: OpenWorkflowRegistry?

    public init(registry: OpenWorkflowRegistry? = nil) {
        self.registry = registry
    }

    public var body: some Scene {
        WindowGroup("Workflow", for: WorkflowWindowData.self) { $data in
            if let data {
                WorkflowContainerHost(data: data, registry: registry)
            }
        }
        .defaultSize(width: 860, height: 540)
        .commands {
            WorkflowCommands()
        }
    }
}

/// Owns the per-window ``WorkflowContainerModel`` in `@State` so it survives view-graph updates. The model
/// is constructed once, when SwiftUI first builds this host for a given window's ``WorkflowWindowData``.
private struct WorkflowContainerHost: View {
    @State private var model: WorkflowContainerModel

    init(data: WorkflowWindowData, registry: OpenWorkflowRegistry?) {
        _model = State(initialValue: WorkflowContainerModel(data: data, registry: registry))
    }

    var body: some View {
        WorkflowContainerView(model: model)
            // The window's own Stop, pressed for it on the way out. Agents left running behind a closed
            // window are work nobody can see, and a Turn suspended in a question is worse than that: the
            // card that was the only way to answer it has just gone with the window, so nothing left on
            // screen will ever end that Turn. Closing is the user saying they're done with this Workflow,
            // and this is that, applied to its agents.
            .onDisappear { model.stopAll() }
    }
}
