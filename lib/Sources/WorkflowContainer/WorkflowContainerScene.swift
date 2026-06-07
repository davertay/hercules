import SwiftUI

public struct WorkflowContainerScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup(for: WorkflowWindowData.self) { $data in
            if let data {
                let model = WorkflowContainerModel(data: data)
                WorkflowContainerView(model: model)
                    .navigationTitle(model.title)
            }
        }
        .commands {
            WorkflowCommands()
        }
    }
}
