import SwiftUI

public struct WorkflowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Workflow") {
                newWorkflow(openWindow: openWindow)
            }
        }
    }
}
