import Design
import SwiftUI

public struct WorkflowContainerView: View {
    let model: WorkflowContainerModel
    @State private var selectedPhase: Phase? = .design

    public init(model: WorkflowContainerModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(Phase.allCases, selection: $selectedPhase) { phase in
                Text(phase.title)
            }
            .navigationTitle(model.title)
        } detail: {
            switch selectedPhase {
            case .design:
                DesignView()
            case .some(let phase):
                PhasePlaceholderView(phase: phase)
            case .none:
                ContentUnavailableView("Select a Phase", systemImage: "sidebar.left")
            }
        }
    }
}

struct PhasePlaceholderView: View {
    let phase: Phase

    var body: some View {
        ContentUnavailableView {
            Label(phase.title, systemImage: "lock")
        } description: {
            Text("The \(phase.title) Phase isn't available yet.")
        }
        .navigationTitle(phase.title)
    }
}

#Preview {
    WorkflowContainerView(
        model: WorkflowContainerModel(
            data: WorkflowWindowData(
                id: UUID(),
                directory: URL(fileURLWithPath: "/tmp/workflow"),
                repoPath: "/path/to/repo"
            )
        )
    )
}
