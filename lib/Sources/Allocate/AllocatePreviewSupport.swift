#if DEBUG
import Foundation
import SQLiteData
import Store

extension AllocateModel {
    /// Seeds a settled Allocate conversation and committed Issue set for the preview harness, standing
    /// in for a propose → accept run so the surface renders without an Agent.
    public static func seedCommittedIssuesPreview(at directory: URL, workflowID: UUID) throws {
        let database = try openWorkflowDatabase(at: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID()
        let proposeTurn = UUID()
        let commitTurn = UUID()

        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/path/to/repo", createdAt: now, updatedAt: now)
            }
            .execute(db)
            // The completed PRD/Design Phases the proposal was grounded in.
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(), workflowID: workflowID, kind: "design", status: "complete",
                    artifactPath: "/wf/phases/design/summary.md", createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            try PhaseRow.insert {
                PhaseRow(
                    id: UUID(), workflowID: workflowID, kind: "prd", status: "complete",
                    artifactPath: "/wf/phases/prd/prd.md", createdAt: now, updatedAt: now
                )
            }
            .execute(db)

            // The settled Allocate Session: a proposal Turn and a commit Turn.
            try SessionRow.insert {
                SessionRow(
                    id: sessionID, workflowID: workflowID, worktreePath: "/path/to/repo",
                    mode: "readOnly", kind: "allocate", createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: proposeTurn, sessionID: sessionID,
                    userPrompt: "Read the PRD and the Design summary, then propose the breakdown into Issues as plain text. Do not write any Issues yet.",
                    finalAnswer: "", createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(), turnID: proposeTurn, position: 0, role: "assistant", kind: "text",
                    text: """
                    Here's a proposed breakdown into 3 Issues:

                    **#1 Add the `issue` table and `IssueRow`** — schema + migration, no dependencies.
                    **#2 Build the create-issue MCP server** — depends on #1.
                    **#3 Wire the Allocate surface** — depends on #1 and #2.

                    Let me know if you'd like to split, merge, or re-order any of these.
                    """,
                    createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            try TurnRow.insert {
                TurnRow(
                    id: commitTurn, sessionID: sessionID,
                    userPrompt: "Write the agreed set of Issues now, one create_issue call per Issue.",
                    finalAnswer: "", createdAt: now.addingTimeInterval(1), updatedAt: now
                )
            }
            .execute(db)
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(), turnID: commitTurn, position: 0, role: "assistant", kind: "text",
                    text: "Done — wrote 3 Issues.", createdAt: now.addingTimeInterval(1), updatedAt: now
                )
            }
            .execute(db)

            // The committed Issue set.
            let issues: [IssueRow] = [
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: 1,
                    title: "Add the issue table and IssueRow",
                    body: "A new idempotent migration adds the issue table (workflowID, number, title, body, dependencies JSON, status) and a public IssueRow type.",
                    dependencies: [], createdAt: now, updatedAt: now
                ),
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: 2,
                    title: "Build the create-issue MCP server",
                    body: "A stdio MCP server target serving a create_issue tool that inserts one IssueRow into the launch-argument database.",
                    dependencies: [1], createdAt: now, updatedAt: now
                ),
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: 3,
                    title: "Wire the Allocate surface",
                    body: "AllocateView + WorkflowContainer wiring: intake action, transcript, composer, the Issue list, and the Accept & Write banner.",
                    dependencies: [1, 2], createdAt: now, updatedAt: now
                ),
            ]
            for issue in issues {
                try IssueRow.insert { issue }.execute(db)
            }
        }
    }

    /// Eagerly loads the Issue fetch so the list is populated before the screenshot, not racing it.
    public func loadIssuesForPreview() async {
        try? await $issues.load()
    }
}
#endif
