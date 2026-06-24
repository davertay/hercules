import Allocate
import Design
import Execute
import PRD
import SwiftUI
import Validate

public struct WorkflowContainerView: View {
    let model: WorkflowContainerModel
    @State private var selectedPhase: Phase? = .design
    @State private var isConfirmingDestroy = false
    @Environment(\.dismiss) private var dismiss

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
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    isConfirmingDestroy = true
                } label: {
                    Label("Destroy Workflow", systemImage: "trash")
                }
                // Always visible, but only while the whole Workflow is quiescent — destroying mid-run would
                // pull the rug from under a live agent.
                .disabled(!model.isIdle)
                .help("Permanently remove this Workflow — enabled only while it's idle")
            }
        }
        .confirmationDialog(
            "Destroy this Workflow?",
            isPresented: $isConfirmingDestroy,
            titleVisibility: .visible
        ) {
            Button("Destroy Workflow", role: .destructive) { destroy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes the Workflow and destroys any commits that aren't merged elsewhere. This can't be undone."
            )
        }
        .overlay(alignment: .bottom) {
            if let notice = model.cleanupNotice {
                CleanupNotice(message: notice)
            }
        }
    }

    /// Tears down the Workflow and closes the window. A clean teardown closes immediately; a git-cleanup
    /// failure first surfaces a brief non-blocking notice — the removal is done regardless — then closes.
    private func destroy() {
        if model.destroy() {
            dismiss()
        } else {
            Task {
                try? await Task.sleep(for: .seconds(4))
                dismiss()
            }
        }
    }
}

/// The transient bottom toast warning that teardown left git state needing manual cleanup. Mirrors the
/// Validate Phase's pushed-confirmation toast.
private struct CleanupNotice: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
