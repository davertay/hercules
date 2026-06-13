import Design
import Foundation
import SwiftUI
import WorkflowContainer

/// Debug-only preview harness — renders a single feature surface in a
/// dedicated window when the `HERCULES_PREVIEW` env var is set, bypassing
/// the Launcher and the on-disk project/flow/ticket setup the production
/// Scene requires. Used for taking screenshots of individual features.
public enum PreviewTarget: String, CaseIterable, Sendable {
    case workflowEmpty
    case designIntake

    public static func fromEnvironment() -> PreviewTarget? {
        guard
            let raw = ProcessInfo.processInfo.environment["HERCULES_PREVIEW"],
            !raw.isEmpty
        else {
            return nil
        }
        return PreviewTarget(rawValue: raw)
    }
}

// Debug-only escape hatch: when `HERCULES_PREVIEW` is set,
// the launcher window renders the `PreviewHarnessEscapeHatch`
// instead of the real launcher chrome.
public struct PreviewHarnessEscapeHatch: View {
    public let target: PreviewTarget

    public var body: some View {
#if DEBUG
        PreviewHarnessView(target: target)
#else
        PreviewUnavailableView()
#endif
    }
}

public struct PreviewUnavailableView: View {
    public var body: some View {
        VStack() {
            Spacer()
            Image(systemName: "hammer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            VStack() {
                Text("Preview harness unavailable")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG

public struct PreviewHarnessView: View {
    public let target: PreviewTarget

    public init(target: PreviewTarget) {
        self.target = target
    }

    public var body: some View {
        switch target {
        case .workflowEmpty:
            WorkflowEmptyPreviewHost()
        case .designIntake:
            DesignIntakePreviewHost()
        }
    }
}

private struct WorkflowEmptyPreviewHost: View {
    @State var model = WorkflowContainerModel(
        data: WorkflowWindowData(
            id: UUID(),
            directory: URL(fileURLWithPath: "/tmp/workflow"),
            repoPath: "/path/to/repo"
        )
    )

    var body: some View {
        WorkflowContainerView(model: model)
            .frame(minWidth: 800, minHeight: 600)
    }
}

/// Renders the Design Phase in isolation in its intake state — an empty engine, so the surface shows
/// the "What are we building today?" prompt and composer. Reuses `WorkflowContainerModel` so the
/// Workflow database is opened and its dependency scoped exactly as in production.
private struct DesignIntakePreviewHost: View {
    @State var container = WorkflowContainerModel(
        data: WorkflowWindowData(
            id: UUID(),
            directory: URL(fileURLWithPath: "/tmp/workflow-design-intake"),
            repoPath: "/path/to/repo"
        )
    )

    var body: some View {
        NavigationStack {
            if let designModel = container.designModel {
                DesignView(model: designModel)
            } else {
                ContentUnavailableView(
                    "Workflow store unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#endif
