/// Fixed at creation, a Workflow's mode shapes its whole Phase topology. `standard` runs all five
/// Phases (Design → PRD → Allocate → Execute → Validate); `small` is the lighter three-Phase Small Job
/// (Design → Execute → Validate), where the Design Phase grills *and* carves Issues in one chat, so PRD
/// and Allocate are skipped entirely. Persisted on the `workflow` row; never changes mid-flight.
public enum WorkflowMode: String, Codable, Sendable, CaseIterable {
    case standard
    case small
}
