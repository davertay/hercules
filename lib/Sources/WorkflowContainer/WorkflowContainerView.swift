import Allocate
import Design
import PRD
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
            case .some(let phase):
                PhasePlaceholderView(phase: phase, isUnlocked: true)
            case .none:
                ContentUnavailableView("Select a Phase", systemImage: "sidebar.left")
            }
        }
    }
}

/// A sidebar row showing a Phase's title and, while the Phase is still gated, a lock badge. Locked
/// rows are dimmed so the enabled/locked state reads at a glance.
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

/// Detail view for a Phase with no real view yet. A locked Phase explains which Phase unlocks it;
/// an unlocked-but-unbuilt Phase notes it is on the way.
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
