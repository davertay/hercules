#if DEBUG
import Foundation
import SQLiteData
import Store

extension ValidateModel {
    /// Seeds a Workflow whose upstream Phases (through Execute) are complete and whose Code Quality
    /// Persona has produced a Summary, so the Validate surface renders a reviewed card and its inspector
    /// without an Agent.
    public static func seedReviewsPreview(at directory: URL, workflowID: UUID) throws {
        let database = try openWorkflowDatabase(at: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/path/to/repo", createdAt: now, updatedAt: now)
            }
            .execute(db)
            // The completed upstream Phases that unlock Validate.
            for kind in ["design", "prd", "allocate", "execute"] {
                try PhaseRow.insert {
                    PhaseRow(
                        id: UUID(), workflowID: workflowID, kind: kind, status: "complete",
                        createdAt: now, updatedAt: now
                    )
                }
                .execute(db)
            }

            try ReviewRow.insert {
                ReviewRow(
                    id: UUID(), workflowID: workflowID, kind: ReviewPersona.codeQuality.rawValue,
                    status: ReviewStatus.reviewed.rawValue,
                    summary: """
                        The branch reads cleanly overall. A few notes:

                        - `WorktreeClient` duplicates the origin-parsing logic that already lives in \
                        `LiveGit`; consider extracting a shared helper.
                        - Several view structs repeat the markdown-rendering helper — a single shared \
                        modifier would remove the duplication.
                        - Naming is consistent with the surrounding modules.
                        """,
                    sessionID: UUID(), createdAt: now, updatedAt: now
                )
            }
            .execute(db)
        }
    }

    /// Eagerly loads the review fetch so the cards are populated before the screenshot, not racing it.
    public func loadReviewsForPreview() async {
        try? await $reviews.load()
    }
}
#endif
