#if DEBUG
import Foundation
import SQLiteData
import Store

extension ExecuteModel {
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
                         body: """
                         ## Goal

                         Lay the module's foundations: the empty `Store` target, its \
                         `Package.swift` entry, and a smoke test that imports it.

                         ## Acceptance criteria

                         - [ ] `Store` target exists and builds.
                         - [ ] A trivial test imports it and passes.
                         """,
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
                         dependencies: [3, 4], status: "failed",
                         failureReason: "Harness binary not found at /Users/admin/.local/bin/claude.",
                         createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 7, title: "Cancelled spike",
                         dependencies: [2], status: "skipped", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 8, title: "Don't persist blank rows",
                         dependencies: [], status: "proposed", createdAt: now, updatedAt: now),
                IssueRow(id: UUID(), workflowID: workflowID, number: 9, title: "Remove duplicate modifier",
                         dependencies: [], status: "proposed", createdAt: now, updatedAt: now),
            ]
            for issue in issues {
                try IssueRow.insert { issue }.execute(db)
            }

            try seedActivityPreview(
                db, workflowID: workflowID, issueNumber: 1,
                tools: 21, steps: 9, durationMs: 83_000, costUSD: 0.04, now: now,
                finalAnswer: """
                Added the `Store` target and wired it into `Package.swift`, then landed a smoke test \
                that imports it and asserts a trivial round-trip.

                - Created `Sources/Store` with an empty `Store.swift`.
                - Registered the target and its test target in `Package.swift`.
                - Added `StoreSmokeTests` — imports `Store` and passes.

                Everything builds and the new test is green.
                """
            )
            try seedActivityPreview(
                db, workflowID: workflowID, issueNumber: 3,
                tools: 5, steps: 2, durationMs: nil, costUSD: nil, now: now
            )
            try seedActivityPreview(
                db, workflowID: workflowID, issueNumber: 6,
                tools: 12, steps: 3, durationMs: 12_000, costUSD: 0.01, now: now
            )
        }
    }

    private static func seedActivityPreview(
        _ db: Database, workflowID: UUID, issueNumber: Int, tools: Int, steps: Int,
        durationMs: Int?, costUSD: Double?, now: Date, finalAnswer: String? = nil
    ) throws {
        let sessionID = UUID()
        let turnID = UUID()
        try SessionRow.insert {
            SessionRow(
                id: sessionID, workflowID: workflowID, worktreePath: "/worktree",
                mode: "write", kind: SessionKind.execute.rawValue, issueNumber: issueNumber,
                createdAt: now, updatedAt: now
            )
        }
        .execute(db)
        try TurnRow.insert {
            TurnRow(
                id: turnID, sessionID: sessionID, finalAnswer: finalAnswer,
                durationMs: durationMs, costUSD: costUSD, createdAt: now, updatedAt: now
            )
        }
        .execute(db)
        var position = 0
        for _ in 0..<tools {
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(), turnID: turnID, position: position, role: "assistant", kind: "tool_use",
                    toolName: "Edit", createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            position += 1
        }
        for _ in 0..<steps {
            try ContentBlockRow.insert {
                ContentBlockRow(
                    id: UUID(), turnID: turnID, position: position, role: "assistant", kind: "text",
                    createdAt: now, updatedAt: now
                )
            }
            .execute(db)
            position += 1
        }
    }

    public func loadIssuesForPreview() async {
        try? await $issues.load()
        try? await $activityCounts.load()
    }
}
#endif
