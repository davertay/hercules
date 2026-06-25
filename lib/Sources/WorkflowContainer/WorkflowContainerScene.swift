import SwiftUI

public struct WorkflowContainerScene: Scene {
    private let registry: OpenWorkflowRegistry?

    public init(registry: OpenWorkflowRegistry? = nil) {
        self.registry = registry
    }

    public var body: some Scene {
        WindowGroup("Workflow", for: WorkflowWindowData.self) { $data in
            if let data {
                let model = WorkflowContainerModel(data: data, registry: registry)
                WorkflowContainerView(model: model)
                    .navigationTitle(model.title)
            }
        }
        .commands {
            WorkflowCommands()
        }
    }
}
