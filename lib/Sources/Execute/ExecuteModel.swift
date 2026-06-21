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

    /// The Issue `number` of the node currently selected in the DAG, driving the inspector pane. `nil`
    /// when nothing is selected.
    public var selectedID: Int?

    /// The Workflow's git worktree — the working tree every Phase operates in. Carried so the health
    /// check can name the expected location in its error.
    @ObservationIgnored
    private let worktree: URL

    /// Whether the Workflow's worktree is absent from disk, evaluated once when the window opens
    /// (creation or state-restored reopen). A `true` value means the expected `worktree/` directory was
    /// pruned or deleted outside Hercules; the Phase surfaces a blocking error rather than silently
    /// falling back to the user's raw checkout.
    public let worktreeMissing: Bool

    public init(workflowID: UUID, database: any DatabaseWriter, worktree: URL) {
        self.worktree = worktree
        worktreeMissing = !FileManager.default.fileExists(atPath: worktree.path)
        _issues = Fetch(
            wrappedValue: [],
            WorkflowIssuesRequest(workflowID: workflowID),
            animation: .default
        )
    }

    /// A human-readable description of the missing-worktree health-check failure, naming where the
    /// worktree was expected, or `nil` when it is present.
    public var worktreeMessage: String? {
        guard worktreeMissing else { return nil }
        return "This Workflow's git worktree is missing — expected at \(worktree.path). It may have been pruned or deleted outside Hercules. Recreating it isn't supported yet, so the Execute Phase can't run until it's restored."
    }

    /// True before any Issue exists — drives the empty-state placeholder. In practice Execute only
    /// unlocks once Allocate has committed at least one Issue, but the guard keeps the view honest.
    public var isEmpty: Bool { issues.isEmpty }

    /// The committed Issues projected to DAG nodes, with `ready` derived from the dependency graph.
    public var nodes: [DAGNode] { dagNodes(from: issues) }

    /// The graph-level validation failure, if any: a dependency cycle or a reference to an unknown
    /// Issue number. `nil` when the graph is a well-formed DAG. The view shows a banner and degrades to
    /// a plain Issue list when this is non-nil, since `layeredLayout`'s precondition is validated input.
    public var validationError: IssueGraph.ValidateError? {
        do {
            try IssueGraph.validate(nodes)
            return nil
        } catch let error as IssueGraph.ValidateError {
            return error
        } catch {
            return nil
        }
    }

    /// A human-readable description of `validationError`, naming the offending Issues, or `nil` when the
    /// graph is valid.
    public var validationMessage: String? {
        switch validationError {
        case .cycle(let involving):
            let list = involving.map { "#\($0)" }.joined(separator: ", ")
            return "These Issues form a dependency cycle: \(list). Resolve it in the Allocate Phase before the graph can be laid out."
        case .unknownDependency(let node, let dep):
            return "Issue #\(node) depends on #\(dep), which doesn't exist. Fix the dependency in the Allocate Phase."
        case .none:
            return nil
        }
    }

    /// Row/column coordinates for the current nodes, consumed by `DAGGraphView`. Empty when the graph
    /// fails validation, so `layeredLayout` is never run on a cycle (which it isn't defined for).
    public var layoutNodes: [IssueGraph.LayoutNode] {
        guard validationError == nil else { return [] }
        return IssueGraph.layeredLayout(nodes)
    }

    /// The current nodes keyed by Issue number, the lookup `DAGGraphView` resolves edges and cards
    /// against.
    public var nodesByNumber: [Int: DAGNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.number, $0) })
    }

    /// The committed Issue backing the current selection, for the inspector pane. `nil` when nothing is
    /// selected (or the selected Issue has since disappeared).
    public var selectedIssue: IssueRow? {
        guard let selectedID else { return nil }
        return issues.first { $0.number == selectedID }
    }

    /// Toggles selection of the node with `number`: selecting an unselected node, or clearing the
    /// selection when its own node is tapped again. The View dispatches the raw tap; the model owns the
    /// toggle/clear policy.
    public func selectNode(_ number: Int) {
        selectedID = selectedID == number ? nil : number
    }
}
