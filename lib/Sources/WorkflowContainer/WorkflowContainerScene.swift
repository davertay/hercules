import SwiftUI

public struct WorkflowContainerScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup("Workflow", for: WorkflowWindowData.self) { $data in
            if let data {
                let model = WorkflowContainerModel(data: data)
                WorkflowContainerView(model: model)
                    .navigationTitle("Scene Title")
            }
        }
        .commands {
            WorkflowCommands()
        }
    }
}
