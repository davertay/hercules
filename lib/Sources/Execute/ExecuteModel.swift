import Foundation
import IssueGraph
import Observation
import SQLiteData
import Store

/// Drives the Execute Phase's visualization: a read-only dependency DAG of the Workflow's committed
/// Issues. Unlike the Design/PRD/Allocate models it owns no chat and spawns no Agent — it observes the
/// Issue rows and projects them into the DAG the view renders. (Scheduling and per-Issue agent runs are
/// later slices.)
///
/// The committed Issues are observed live via `WorkflowIssuesRequest`, so the graph appears the moment
/// the Allocate commit Turn writes and survives reopening the window. The `IssueRow` → `DAGNode`
/// mapping (`dagNodes(from:)`) derives each node's status from the dependency graph.
@MainActor
@Observable
public final class ExecuteModel {
    /// Live view of this Workflow's committed Issues, ordered by number. Drives the DAG; updates as the
    /// underlying rows change.
    @ObservationIgnored
    @Fetch var issues: [IssueRow] = []

    public init(workflowID: UUID, database: any DatabaseWriter) {
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// True before any Issue exists — drives the empty-state placeholder. In practice Execute only
    /// unlocks once Allocate has committed at least one Issue, but the guard keeps the view honest.
    public var isEmpty: Bool { issues.isEmpty }

    /// The committed Issues projected to DAG nodes, with `ready` derived from the dependency graph.
    public var nodes: [DAGNode] { dagNodes(from: issues) }

    /// Row/column coordinates for the current nodes, consumed by `DAGGraphView`.
    public var layoutNodes: [IssueGraph.LayoutNode] { IssueGraph.layeredLayout(nodes) }

    /// The current nodes keyed by Issue number, the lookup `DAGGraphView` resolves edges and cards
    /// against.
    public var nodesByNumber: [Int: DAGNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })
    }
}
