import Allocate
import Design
import Execute
import UISupport
import SwiftUI
import Validate

public struct WorkflowContainerView: View {
    let model: WorkflowContainerModel
    @State private var selectedPhase: Phase? = .design
    @State private var showingSettings = false
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
        } detail: {
            phaseDetail
                .navigationTitle(model.title)
                .navigationSubtitle(model.subtitle(phase: selectedPhase))
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Workflow Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    model.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                // Always visible; enabled only while the Workflow is busy. Stop and Destroy are mutually
                // exclusive, so their greyed states read as the Workflow's busy/idle status at a glance.
                .disabled(!model.isRunning)
                .help("Stop every running agent across all Phases — enabled only while the Workflow is busy")
            }
            ToolbarItem(placement: .destructiveAction) {
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
        .destroyWorkflowConfirmationDialog(isPresented: $isConfirmingDestroy, action: destroy)
        .overlay(alignment: .bottom) {
            if let notice = model.cleanupNotice {
                TransientToast(message: notice, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
            }
        }
        .sheet(isPresented: $showingSettings) {
            WorkflowSettingsView(model: model)
        }
    }

    @ViewBuilder
    private var phaseDetail: some View {
        switch selectedPhase {
        case .some(let phase) where !model.isUnlocked(phase):
            PhasePlaceholderView(phase: phase, isUnlocked: false, predecessor: phase.predecessor)
        case .design:
            if let designModel = model.designModel {
                DesignView(model: designModel)
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
            PhasePlaceholderView(phase: phase, isUnlocked: true, predecessor: phase.predecessor)
        case .none:
            ContentUnavailableView("Select a Phase", systemImage: "sidebar.left")
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
    /// The Phase that gates this one, used for the locked-state copy.
    var predecessor: Phase?

    var body: some View {
        ContentUnavailableView {
            Label(phase.title, systemImage: isUnlocked ? "hammer" : "lock")
        } description: {
            Text(description)
        }
    }

    private var description: String {
        if isUnlocked {
            "The \(phase.title) Phase isn't built yet."
        } else if let predecessor {
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
