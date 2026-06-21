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

        // The table is queryable (columns present) and starts empty.
        let count = try database.read { db in try IssueRow.fetchAll(db).count }
        #expect(count == 0)

        // The workflowID index is present.
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
        // The target Workflow's live Issues are soft-deleted and stamped.
        #expect(byID[UUID(10)]?.isDeleted == true)
        #expect(byID[UUID(11)]?.isDeleted == true)
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // An already-deleted Issue is left untouched (its updatedAt is not re-stamped).
        #expect(byID[UUID(12)]?.isDeleted == true)
        #expect(byID[UUID(12)]?.updatedAt == Self.fixedDate)
        // The other Workflow's Issue is untouched.
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
        // The targeted Issue carries the new raw string and a fresh timestamp.
        #expect(byID[UUID(10)]?.status == "in_progress")
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // A sibling Issue is untouched.
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
        // A same-numbered Issue in another Workflow, and a soft-deleted Issue in the target.
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
        // The other Workflow's same-numbered Issue is untouched.
        #expect(byID[UUID(11)]?.status == "new")
        // The soft-deleted Issue is not revived or restamped.
        #expect(byID[UUID(12)]?.status == "new")
        #expect(byID[UUID(12)]?.updatedAt == Self.fixedDate)
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
        // The stale in-progress Issue is demoted and restamped.
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
        // The other Workflow's in-progress Issue is untouched.
        #expect(byID[UUID(11)]?.status == "in_progress")
        // A soft-deleted in-progress Issue is left as-is.
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
}
