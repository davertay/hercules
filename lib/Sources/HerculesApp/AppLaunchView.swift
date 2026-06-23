import SwiftUI
import WorkflowContainer

public struct AppLaunchView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var workflows: [WorkflowSummary] = []

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

            if !workflows.isEmpty {
                Divider()
                Text("Open Existing")
                    .font(.headline)
                List(workflows) { workflow in
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
                }
                .frame(minWidth: 320, minHeight: 160)
            }
        }
        .padding(40)
        .task { workflows = listWorkflows() }
    }
}

#Preview {
    AppLaunchView(model: AppModel())
}
