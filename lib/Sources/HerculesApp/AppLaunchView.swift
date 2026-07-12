import Store
import SwiftUI
import WorkflowContainer

public struct AppLaunchView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var workflows: [WorkflowSummary] = []
    @State private var pendingDeletion: WorkflowSummary?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Hercules")
                .font(.largeTitle)
            Button("New Workflow") {
                newWorkflow(openWindow: openWindow)
            }
            .buttonStyle(.borderedProminent)

            if !workflows.isEmpty {
                Divider()
                Text("Open Existing")
                    .font(.headline)
                List(workflows) { workflow in
                    HStack {
                        Button {
                            openWindow(value: workflow.data)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workflow.title)
                                Text(workflow.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            pendingDeletion = workflow
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        // Always visible; destroying from the launcher is only allowed while no window is
                        // open for the Workflow. With a window open, you destroy from its idle-gated toolbar.
                        .disabled(model.openWorkflows.isOpen(workflow.id))
                        .help(
                            model.openWorkflows.isOpen(workflow.id)
                                ? "Close the open window to destroy this Workflow, or use its Destroy button"
                                : "Permanently remove this Workflow"
                        )
                    }
                }
                .frame(minWidth: 320, minHeight: 160)
            }
        }
        .padding(40)
        .task { workflows = listWorkflows() }
        .destroyWorkflowConfirmationDialog(
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            if let workflow = pendingDeletion { destroy(workflow) }
        }
    }

    /// Tears down the Workflow and refreshes the list so the removed row disappears immediately. Folder
    /// removal is the operation of record, so the Workflow is gone from the list even if a git step failed.
    private func destroy(_ workflow: WorkflowSummary) {
        deleteWorkflow(data: workflow.data)
        workflows = listWorkflows()
    }
}

#Preview {
    AppLaunchView(model: AppModel())
}
