import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("Issue")
struct IssueTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Migration

    @Test func migrationCreatesIssueTableAndIndex() throws {
        let database = try Self.makeDatabase()

        let count = try database.read { db in try IssueRow.fetchAll(db).count }
        #expect(count == 0)

        let indexNames = try database.read { db in
            try #sql(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'issue'",
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(indexNames.contains("index_issue_on_workflowID"))
    }

    @Test func issueRowRoundTrips() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: UUID(2), workflowID: workflowID, number: 7, title: "Add issue table",
                    body: "The bulk spec.", dependencies: [3, 5], status: "new",
                    createdAt: Self.fixedDate, updatedAt: Self.fixedDate
                )
            }
            .execute(db)
        }

        let row = try database.read { db in try IssueRow.fetchOne(db) }
        #expect(row?.id == UUID(2))
        #expect(row?.workflowID == workflowID)
        #expect(row?.number == 7)
        #expect(row?.title == "Add issue table")
        #expect(row?.body == "The bulk spec.")
        #expect(row?.dependencies == [3, 5])
        #expect(row?.status == "new")
        #expect(row?.isDeleted == false)
    }

    // MARK: - clearIssues

    @Test func clearIssuesSoftDeletesOnlyTheTargetWorkflow() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: target, number: 1)
        try Self.seedIssue(database, id: UUID(11), workflowID: target, number: 2)
        try Self.seedIssue(database, id: UUID(12), workflowID: target, number: 3, isDeleted: true)
        try Self.seedIssue(database, id: UUID(13), workflowID: other, number: 1)

        try database.clearIssues(workflowID: target, now: Self.fixedDate.addingTimeInterval(60))

        let rows = try database.read { db in
            try IssueRow.fetchAll(db)
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.isDeleted == true)
        #expect(byID[UUID(11)]?.isDeleted == true)
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // An already-deleted Issue is left untouched (updatedAt not re-stamped).
        #expect(byID[UUID(12)]?.isDeleted == true)
        #expect(byID[UUID(12)]?.updatedAt == Self.fixedDate)
        // The other Workflow is untouched.
        #expect(byID[UUID(13)]?.isDeleted == false)
        #expect(byID[UUID(13)]?.updatedAt == Self.fixedDate)
    }

    // MARK: - setIssueStatus

    @Test func setIssueStatusWritesRawStringAndStampsUpdatedAt() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1)
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2)

        try database.setIssueStatus(
            workflowID: workflowID, number: 1, to: .inProgress,
            now: Self.fixedDate.addingTimeInterval(60)
        )

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "in_progress")
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        #expect(byID[UUID(11)]?.status == "new")
        #expect(byID[UUID(11)]?.updatedAt == Self.fixedDate)
    }

    @Test func setIssueStatusPersistsDoneAndFailedRawStrings() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1)
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2)

        try database.setIssueStatus(workflowID: workflowID, number: 1, to: .done, now: Self.fixedDate)
        try database.setIssueStatus(workflowID: workflowID, number: 2, to: .failed, now: Self.fixedDate)

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "done")
        #expect(byID[UUID(11)]?.status == "failed")
    }

    @Test func setIssueStatusScopesToTheTargetWorkflowAndSkipsDeleted() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: target, number: 1)
        try Self.seedIssue(database, id: UUID(11), workflowID: other, number: 1)
        try Self.seedIssue(database, id: UUID(12), workflowID: target, number: 1, isDeleted: true)

        try database.setIssueStatus(
            workflowID: target, number: 1, to: .done,
            now: Self.fixedDate.addingTimeInterval(60)
        )

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "done")
        // Other Workflow's same-numbered Issue, and a soft-deleted one, are untouched.
        #expect(byID[UUID(11)]?.status == "new")
        #expect(byID[UUID(12)]?.status == "new")
        #expect(byID[UUID(12)]?.updatedAt == Self.fixedDate)
    }

    @Test func setIssueStatusWritesFailureReasonAndClearsItOnRecovery() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1)

        try database.setIssueStatus(
            workflowID: workflowID, number: 1, to: .failed,
            failureReason: "boom", now: Self.fixedDate
        )
        #expect(try database.read { db in try IssueRow.fetchOne(db) }?.failureReason == "boom")

        // A later non-failed transition passes nil, clearing the stale reason.
        try database.setIssueStatus(workflowID: workflowID, number: 1, to: .done, now: Self.fixedDate)
        #expect(try database.read { db in try IssueRow.fetchOne(db) }?.failureReason == nil)
    }

    // MARK: - resetIssue

    @Test func resetIssueReturnsFailedIssueToNewAndClearsReasonOnlyForFailed() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1, status: "failed")
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2, status: "done")
        try database.setIssueStatus(
            workflowID: workflowID, number: 1, to: .failed, failureReason: "boom", now: Self.fixedDate
        )

        try database.resetIssue(
            workflowID: workflowID, number: 1, now: Self.fixedDate.addingTimeInterval(60)
        )
        // A done Issue is left alone — reset only rescues failures.
        try database.resetIssue(workflowID: workflowID, number: 2, now: Self.fixedDate)

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "new")
        #expect(byID[UUID(10)]?.failureReason == nil)
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        #expect(byID[UUID(11)]?.status == "done")
    }

    // MARK: - approveIssue

    @Test func approveIssuePromotesProposedToNewAndStampsUpdatedAt() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1, status: "proposed")
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2, status: "new")

        try database.approveIssue(workflowID: workflowID, number: 1, now: Self.fixedDate.addingTimeInterval(60))

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "new")
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // A non-proposed Issue is left alone.
        #expect(byID[UUID(11)]?.status == "new")
        #expect(byID[UUID(11)]?.updatedAt == Self.fixedDate)
    }

    @Test func approveIssueSkipsDeletedAndOtherWorkflow() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: target, number: 1, status: "proposed")
        try Self.seedIssue(database, id: UUID(11), workflowID: other, number: 1, status: "proposed")
        try Self.seedIssue(database, id: UUID(12), workflowID: target, number: 2, status: "proposed", isDeleted: true)

        try database.approveIssue(workflowID: target, number: 1, now: Self.fixedDate.addingTimeInterval(60))

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "new")
        // The other Workflow's and the soft-deleted proposed Issue are untouched.
        #expect(byID[UUID(11)]?.status == "proposed")
        #expect(byID[UUID(12)]?.status == "proposed")
        #expect(byID[UUID(12)]?.isDeleted == true)
    }

    // MARK: - denyIssue

    @Test func denyIssueSoftDeletesProposedAndStampsUpdatedAt() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1, status: "proposed")
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2, status: "new")

        try database.denyIssue(workflowID: workflowID, number: 1, now: Self.fixedDate.addingTimeInterval(60))

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.isDeleted == true)
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // A non-proposed Issue is left alone.
        #expect(byID[UUID(11)]?.isDeleted == false)
        #expect(byID[UUID(11)]?.updatedAt == Self.fixedDate)
    }

    @Test func denyIssueSkipsNonProposedAndOtherWorkflow() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: target, number: 1, status: "proposed")
        try Self.seedIssue(database, id: UUID(11), workflowID: target, number: 2, status: "done")
        try Self.seedIssue(database, id: UUID(12), workflowID: other, number: 1, status: "proposed")

        try database.denyIssue(workflowID: target, number: 1, now: Self.fixedDate.addingTimeInterval(60))

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.isDeleted == true)
        // A done Issue and the other Workflow's proposed Issue are untouched.
        #expect(byID[UUID(11)]?.isDeleted == false)
        #expect(byID[UUID(12)]?.isDeleted == false)
    }

    // MARK: - reconcileStaleInProgressIssues

    @Test func reconcileDemotesOnlyInProgressIssuesToFailed() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 1, status: "in_progress")
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 2, status: "done")
        try Self.seedIssue(database, id: UUID(12), workflowID: workflowID, number: 3, status: "new")

        try database.reconcileStaleInProgressIssues(
            workflowID: workflowID, now: Self.fixedDate.addingTimeInterval(60)
        )

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "failed")
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // Terminal and pending Issues are left alone.
        #expect(byID[UUID(11)]?.status == "done")
        #expect(byID[UUID(11)]?.updatedAt == Self.fixedDate)
        #expect(byID[UUID(12)]?.status == "new")
        #expect(byID[UUID(12)]?.updatedAt == Self.fixedDate)
    }

    @Test func reconcileScopesToTheTargetWorkflowAndSkipsDeleted() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: target, number: 1, status: "in_progress")
        try Self.seedIssue(database, id: UUID(11), workflowID: other, number: 1, status: "in_progress")
        try Self.seedIssue(
            database, id: UUID(12), workflowID: target, number: 2, status: "in_progress", isDeleted: true
        )

        try database.reconcileStaleInProgressIssues(workflowID: target, now: Self.fixedDate)

        let rows = try database.read { db in try IssueRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "failed")
        // The other Workflow's and the soft-deleted in-progress Issues are left as-is.
        #expect(byID[UUID(11)]?.status == "in_progress")
        #expect(byID[UUID(12)]?.status == "in_progress")
    }

    // MARK: - WorkflowIssuesRequest

    @Test func issuesRequestReturnsNonDeletedOrderedByNumber() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedIssue(database, id: UUID(10), workflowID: workflowID, number: 2)
        try Self.seedIssue(database, id: UUID(11), workflowID: workflowID, number: 1)
        try Self.seedIssue(database, id: UUID(12), workflowID: workflowID, number: 3, isDeleted: true)
        try Self.seedIssue(database, id: UUID(13), workflowID: other, number: 1)

        let issues = try database.read { db in
            try WorkflowIssuesRequest(workflowID: workflowID).fetch(db)
        }

        #expect(issues.map(\.number) == [1, 2])
        #expect(issues.map(\.id) == [UUID(11), UUID(10)])
    }

    // MARK: - IssueFailureReasonsRequest

    @Test func failureReasonsMapEachIssueToItsErroredTurnFinalAnswer() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        // Issue 1: an execute session with an errored Turn carrying the Harness's reason.
        try Self.seedSession(database, id: UUID(20), workflowID: workflowID, issueNumber: 1)
        try Self.seedTurn(
            database, id: UUID(30), sessionID: UUID(20), isError: true,
            finalAnswer: "You've hit your session limit", at: Self.fixedDate
        )
        // Issue 2: a clean (non-errored) Turn — must not appear.
        try Self.seedSession(database, id: UUID(21), workflowID: workflowID, issueNumber: 2)
        try Self.seedTurn(
            database, id: UUID(31), sessionID: UUID(21), isError: false,
            finalAnswer: "All good", at: Self.fixedDate
        )

        let reasons = try database.read { db in
            try IssueFailureReasonsRequest(workflowID: workflowID).fetch(db)
        }

        #expect(reasons == [1: "You've hit your session limit"])
    }

    @Test func failureReasonsPrefersTheLatestErroredTurnAndSkipsEmptyFinalAnswer() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedSession(database, id: UUID(20), workflowID: workflowID, issueNumber: 1)
        // An older failure with a reason, then a newer interrupt (errored, no finalAnswer). The newest
        // Turn wins, so no reason is surfaced and the Issue's own failureReason shows instead.
        try Self.seedTurn(
            database, id: UUID(30), sessionID: UUID(20), isError: true,
            finalAnswer: "API Error: 529 Overloaded", at: Self.fixedDate
        )
        try Self.seedTurn(
            database, id: UUID(31), sessionID: UUID(20), isError: true,
            finalAnswer: nil, at: Self.fixedDate.addingTimeInterval(60)
        )

        let reasons = try database.read { db in
            try IssueFailureReasonsRequest(workflowID: workflowID).fetch(db)
        }

        #expect(reasons.isEmpty)
    }

    @Test func failureReasonsIgnoreNonExecuteSessions() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        // A chat-kind session has no issueNumber tag; its errored Turn must not map to any Issue.
        try Self.seedSession(
            database, id: UUID(20), workflowID: workflowID, issueNumber: nil, kind: .allocate
        )
        try Self.seedTurn(
            database, id: UUID(30), sessionID: UUID(20), isError: true,
            finalAnswer: "irrelevant", at: Self.fixedDate
        )

        let reasons = try database.read { db in
            try IssueFailureReasonsRequest(workflowID: workflowID).fetch(db)
        }

        #expect(reasons.isEmpty)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }

    private static func seedWorkflow(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
        }
    }

    private static func seedIssue(
        _ database: any DatabaseWriter, id: UUID, workflowID: UUID, number: Int,
        status: String = "new", isDeleted: Bool = false
    ) throws {
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: id, workflowID: workflowID, number: number, title: "Issue \(number)",
                    status: status, createdAt: fixedDate, updatedAt: fixedDate, isDeleted: isDeleted
                )
            }
            .execute(db)
        }
    }

    private static func seedSession(
        _ database: any DatabaseWriter, id: UUID, workflowID: UUID, issueNumber: Int?,
        kind: SessionKind = .execute
    ) throws {
        try database.write { db in
            try SessionRow.insert {
                SessionRow(
                    id: id, workflowID: workflowID, worktreePath: "/worktree", mode: "write",
                    kind: kind.rawValue, issueNumber: issueNumber, createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func seedTurn(
        _ database: any DatabaseWriter, id: UUID, sessionID: UUID, isError: Bool,
        finalAnswer: String?, at createdAt: Date
    ) throws {
        try database.write { db in
            try TurnRow.insert {
                TurnRow(
                    id: id, sessionID: sessionID, finalAnswer: finalAnswer, isError: isError,
                    createdAt: createdAt, updatedAt: createdAt
                )
            }
            .execute(db)
        }
    }
}
