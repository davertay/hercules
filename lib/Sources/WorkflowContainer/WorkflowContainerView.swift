import Allocate
import Design
import Execute
import PRD
import SwiftUI
import Validate

public struct WorkflowContainerView: View {
    let model: WorkflowContainerModel
    @State private var selectedPhase: Phase? = .design

    public init(model: WorkflowContainerModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(Phase.allCases, selection: $selectedPhase) { phase in
                PhaseSidebarRow(phase: phase, isUnlocked: model.isUnlocked(phase))
            }
            .navigationTitle(model.title)
        } detail: {
            switch selectedPhase {
            case .some(let phase) where !model.isUnlocked(phase):
                PhasePlaceholderView(phase: phase, isUnlocked: false)
            case .design:
                if let designModel = model.designModel {
                    DesignView(model: designModel)
                } else {
                    ContentUnavailableView(
                        "Workflow store unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .prd:
                if let prdModel = model.prdModel {
                    PRDView(model: prdModel)
                } else {
                    ContentUnavailableView(
                        "Workflow store unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .allocate:
                if let allocateModel = model.allocateModel {
                    AllocateView(model: allocateModel)
                } else {
                    ContentUnavailableView(
                        "Workflow store unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .execute:
                if let executeModel = model.executeModel {
                    ExecuteView(model: executeModel)
                } else {
                    ContentUnavailableView(
                        "Workflow store unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .validate:
                if let validateModel = model.validateModel {
                    ValidateView(model: validateModel)
                } else {
                    ContentUnavailableView(
                        "Workflow store unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .some(let phase):
                PhasePlaceholderView(phase: phase, isUnlocked: true)
            case .none:
                ContentUnavailableView("Select a Phase", systemImage: "sidebar.left")
            }
        }
    }
}

struct PhaseSidebarRow: View {
    let phase: Phase
    let isUnlocked: Bool

    var body: some View {
        HStack {
            Text(phase.title)
            if !isUnlocked {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
            }
        }
        .foregroundStyle(isUnlocked ? .primary : .secondary)
    }
}

/// Detail view for a Phase with no real view yet.
struct PhasePlaceholderView: View {
    let phase: Phase
    let isUnlocked: Bool

    var body: some View {
        ContentUnavailableView {
            Label(phase.title, systemImage: isUnlocked ? "hammer" : "lock")
        } description: {
            Text(description)
        }
        .navigationTitle(phase.title)
    }

    private var description: String {
        if isUnlocked {
            "The \(phase.title) Phase isn't built yet."
        } else if let predecessor = phase.predecessor {
            "The \(phase.title) Phase unlocks once the \(predecessor.title) Phase is complete."
        } else {
            "The \(phase.title) Phase isn't available yet."
        }
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
