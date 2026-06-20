#if DEBUG
import Foundation
import SQLiteData
import Store

extension ExecuteModel {
    /// Seeds a Workflow whose Allocate Phase has committed a dependency graph of Issues into the
    /// database at `directory`, for the preview harness. Stands in for a completed Design → PRD →
    /// Allocate run so the Execute surface renders its DAG without an Agent. Statuses span the
    /// vocabulary so every node colour is exercised; the `"new"` roots derive `.ready`.
    public static func seedCommittedIssuesPreview(at directory: URL, workflowID: UUID) throws {
        let database = try openWorkflowDatabase(at: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/path/to/repo", createdAt: now, updatedAt: now)
            }
            .execute(db)
            // The completed upstream Phases that unlock Execute.
            for kind in ["design", "prd", "allocate"] {
                try PhaseRow.insert {
                    PhaseRow(
                        id: UUID(), workflowID: workflowID, kind: kind, status: "complete",
                        createdAt: now, updatedAt: now
                    )
                }
                .execute(db)
            }

            let issues: [IssueRow] = [
                IssueRow(id: UUID(), workflowID: workflowID, number: 1, title: "Foundations",
                         dependencies: [], status: "done", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 2, title: "Public types",
                         dependencies: [], status: "done", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 3, title: "First tracer",
                         dependencies: [1], status: "in_progress", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 4, title: "Conflict path",
                         dependencies: [1, 2], status: "new", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 5, title: "Recovery branch",
                         dependencies: [3], status: "new", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 6, title: "Wire end-to-end",
                         dependencies: [3, 4], status: "failed", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 7, title: "Cancelled spike",
                         dependencies: [2], status: "skipped", createdAt: now, updatedAt: now),
            ]
            for issue in issues {
                try IssueRow.insert { issue }.execute(db)
            }
        }
    }

    /// Eagerly loads the Issue fetch so the preview's DAG is populated by the time the harness window is
    /// captured, rather than relying on an async on-appear load racing the screenshot.
    public func loadIssuesForPreview() async {
        try? await $issues.load()
    }
}
#endif
