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
            .navigationTitle("Scene Title")
    }
}
