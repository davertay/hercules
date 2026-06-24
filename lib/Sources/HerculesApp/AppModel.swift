import Observation
import WorkflowContainer

@MainActor
@Observable
public final class AppModel {
    public let testChatEnabled: Bool

    /// Tracks which Workflows have an open window. The launcher disables its per-row destroy button while a
    /// window is open for that Workflow; the Workflow Scene registers/unregisters ids against this.
    public let openWorkflows: OpenWorkflowRegistry

    public init(
        testChatEnabled: Bool = false,
        openWorkflows: OpenWorkflowRegistry = OpenWorkflowRegistry()
    ) {
        self.testChatEnabled = testChatEnabled
        self.openWorkflows = openWorkflows
    }
}
