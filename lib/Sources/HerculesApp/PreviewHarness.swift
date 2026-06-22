import Allocate
import DAGGraphUI
import Design
import Execute
import Foundation
import IssueGraph
import SwiftUI
import WorkflowContainer

/// Debug-only preview harness — renders a single feature surface when `HERCULES_PREVIEW` is set,
/// bypassing the Launcher and on-disk setup the production Scene requires. For feature screenshots.
public enum PreviewTarget: String, CaseIterable, Sendable {
    case workflowEmpty
    case designIntake
    case allocateIntake
    case allocateCommitted
    case dagGraph
    case flowExecute

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
        case .allocateIntake:
            AllocateIntakePreviewHost()
        case .allocateCommitted:
            AllocateCommittedPreviewHost()
        case .dagGraph:
            DAGGraphPreviewHost()
        case .flowExecute:
            FlowExecutePreviewHost()
        }
    }
}

/// Renders the Execute Phase end-to-end over fixture Issues seeded into a fresh Workflow database.
private struct FlowExecutePreviewHost: View {
    @State private var container: WorkflowContainerModel

    init() {
        let id = UUID()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workflow-flow-execute-\(id.uuidString)", isDirectory: true)
        try? ExecuteModel.seedCommittedIssuesPreview(at: directory, workflowID: id)
        // Stand in a worktree so Execute's health check passes and the DAG renders.
        try? FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )
        _container = State(
            wrappedValue: WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/path/to/repo")
            )
        )
    }

    var body: some View {
        NavigationStack {
            if let executeModel = container.executeModel {
                ExecuteView(model: executeModel)
                    .task {
                        await executeModel.loadIssuesForPreview()
                        // Pre-select a node so the inspector renders with content.
                        executeModel.selectNode(4)
                    }
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

/// Renders `DAGGraphView` over fixtures exercising every `IssueStatus` and a diamond dependency shape.
/// Stands alone — no Workflow database — since the view is a foundation surface.
private struct DAGGraphPreviewHost: View {
    private static let nodes: [DAGNode] = [
        DAGNode(number: 1, title: "Foundations", status: .done, dependencies: []),
        DAGNode(number: 2, title: "Public types", status: .done, dependencies: []),
        DAGNode(number: 3, title: "First tracer", status: .inProgress, dependencies: [1]),
        DAGNode(number: 4, title: "Conflict path", status: .ready, dependencies: [1, 2]),
        DAGNode(number: 5, title: "Recovery branch", status: .pending, dependencies: [3]),
        DAGNode(number: 6, title: "Wire end-to-end", status: .failed, dependencies: [3, 4]),
        DAGNode(number: 7, title: "Cancelled spike", status: .skipped, dependencies: [2]),
    ]

    var body: some View {
        DAGGraphView(
            layoutNodes: IssueGraph.layeredLayout(Self.nodes),
            nodesByNumber: Dictionary(uniqueKeysWithValues: Self.nodes.map { ($0.number, $0) }),
            metrics: .default,
            palette: .default
        )
        .frame(minWidth: 800, minHeight: 600)
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

/// Renders the Design Phase in its intake state — an empty engine showing the prompt and composer.
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

/// Renders the Allocate Phase in its intake state — an empty engine showing the Propose action.
private struct AllocateIntakePreviewHost: View {
    @State var container = WorkflowContainerModel(
        data: WorkflowWindowData(
            id: UUID(),
            directory: URL(fileURLWithPath: "/tmp/workflow-allocate-intake"),
            repoPath: "/path/to/repo"
        )
    )

    var body: some View {
        NavigationStack {
            if let allocateModel = container.allocateModel {
                AllocateView(model: allocateModel)
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

/// Renders the Allocate Phase after a propose → accept run, from a fixture conversation and Issues
/// seeded into a fresh Workflow database.
private struct AllocateCommittedPreviewHost: View {
    @State private var container: WorkflowContainerModel

    init() {
        let id = UUID()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workflow-allocate-committed-\(id.uuidString)", isDirectory: true)
        try? AllocateModel.seedCommittedIssuesPreview(at: directory, workflowID: id)
        _container = State(
            wrappedValue: WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/path/to/repo")
            )
        )
    }

    var body: some View {
        NavigationStack {
            if let allocateModel = container.allocateModel {
                AllocateView(model: allocateModel)
                    .task { await allocateModel.loadIssuesForPreview() }
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
