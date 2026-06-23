import Dependencies
import Foundation
import SQLiteData
import Testing

@testable import Store

@Suite("Review")
struct ReviewTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Migration

    @Test func migrationCreatesReviewTableAndIndex() throws {
        let database = try Self.makeDatabase()

        let count = try database.read { db in try ReviewRow.fetchAll(db).count }
        #expect(count == 0)

        let indexNames = try database.read { db in
            try #sql(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'review'",
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(indexNames.contains("index_review_on_workflowID_kind"))
    }

    @Test func reviewRowRoundTrips() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try database.write { db in
            try ReviewRow.insert {
                ReviewRow(
                    id: UUID(2), workflowID: workflowID, kind: "security", status: "reviewed",
                    summary: "Looks safe.", failureReason: nil, sessionID: UUID(3),
                    createdAt: Self.fixedDate, updatedAt: Self.fixedDate
                )
            }
            .execute(db)
        }

        let row = try database.read { db in try ReviewRow.fetchOne(db) }
        #expect(row?.id == UUID(2))
        #expect(row?.workflowID == workflowID)
        #expect(row?.kind == "security")
        #expect(row?.status == "reviewed")
        #expect(row?.summary == "Looks safe.")
        #expect(row?.failureReason == nil)
        #expect(row?.sessionID == UUID(3))
        #expect(row?.isDeleted == false)
    }

    // MARK: - upsertReview

    @Test func upsertInsertsAFreshRowWhenThePersonaWasIdle() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .running, now: Self.fixedDate
            )
        }

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.kind == "security")
        #expect(rows.first?.status == "running")
        #expect(rows.first?.summary == nil)
        #expect(rows.first?.failureReason == nil)
        #expect(rows.first?.createdAt == Self.fixedDate)
    }

    @Test func upsertOverwritesTheSameRowPerRunKeepingItsIdentity() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            // First run: running → reviewed with a Summary.
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .running, now: Self.fixedDate
            )
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .reviewed, summary: "First pass.",
                now: Self.fixedDate.addingTimeInterval(60)
            )
            // Second run of the same Persona: a new Summary replaces the prior one in place.
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .reviewed, summary: "Second pass.",
                now: Self.fixedDate.addingTimeInterval(120)
            )
        }

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        // Still one row — upsert, not append.
        #expect(rows.count == 1)
        #expect(rows.first?.status == "reviewed")
        #expect(rows.first?.summary == "Second pass.")
        #expect(rows.first?.createdAt == Self.fixedDate)
        #expect(rows.first?.updatedAt == Self.fixedDate.addingTimeInterval(120))
    }

    @Test func upsertCarriesSummaryAndFailureReasonAndClearsStaleValues() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .failed, failureReason: "boom",
                now: Self.fixedDate
            )
            #expect(try database.read { db in try ReviewRow.fetchOne(db) }?.failureReason == "boom")

            // Re-running: a reviewed transition carries the Summary and clears the stale failure reason.
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .reviewed, summary: "Recovered.",
                now: Self.fixedDate
            )
        }

        let row = try database.read { db in try ReviewRow.fetchOne(db) }
        #expect(row?.status == "reviewed")
        #expect(row?.summary == "Recovered.")
        #expect(row?.failureReason == nil)
    }

    @Test func upsertKeepsADistinctRowPerPersonaKind() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            try database.upsertReview(
                workflowID: workflowID, kind: "security", to: .running, now: Self.fixedDate
            )
            try database.upsertReview(
                workflowID: workflowID, kind: "code-quality", to: .running, now: Self.fixedDate
            )
        }

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        #expect(Set(rows.map(\.kind)) == ["security", "code-quality"])
    }

    @Test func upsertScopesToTheTargetWorkflow() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedReview(database, id: UUID(10), workflowID: other, kind: "security", status: "reviewed")

        try withDependencies {
            $0.uuid = .incrementing
        } operation: {
            try database.upsertReview(
                workflowID: target, kind: "security", to: .running,
                now: Self.fixedDate.addingTimeInterval(60)
            )
        }

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        let byWorkflow = Dictionary(grouping: rows, by: \.workflowID)
        #expect(byWorkflow[target]?.count == 1)
        #expect(byWorkflow[target]?.first?.status == "running")
        // The other Workflow's same-kind review is untouched.
        #expect(byWorkflow[other]?.first?.status == "reviewed")
        #expect(byWorkflow[other]?.first?.updatedAt == Self.fixedDate)
    }

    // MARK: - setReviewSession

    @Test func setReviewSessionLinksTheSessionIDAndStampsUpdatedAt() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedReview(database, id: UUID(10), workflowID: workflowID, kind: "security", status: "running")

        try database.setReviewSession(
            workflowID: workflowID, kind: "security", sessionID: UUID(20),
            now: Self.fixedDate.addingTimeInterval(60)
        )

        let row = try database.read { db in try ReviewRow.fetchOne(db) }
        #expect(row?.sessionID == UUID(20))
        #expect(row?.updatedAt == Self.fixedDate.addingTimeInterval(60))
    }

    // MARK: - reconcileStaleRunningReviews

    @Test func reconcileDemotesOnlyRunningReviewsToFailed() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedReview(database, id: UUID(10), workflowID: workflowID, kind: "security", status: "running")
        try Self.seedReview(database, id: UUID(11), workflowID: workflowID, kind: "code-quality", status: "reviewed")

        try database.reconcileStaleRunningReviews(
            workflowID: workflowID, now: Self.fixedDate.addingTimeInterval(60)
        )

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "failed")
        #expect(byID[UUID(10)]?.failureReason?.isEmpty == false)
        #expect(byID[UUID(10)]?.updatedAt == Self.fixedDate.addingTimeInterval(60))
        // A reviewed review is left alone.
        #expect(byID[UUID(11)]?.status == "reviewed")
        #expect(byID[UUID(11)]?.updatedAt == Self.fixedDate)
    }

    @Test func reconcileScopesToTheTargetWorkflowAndSkipsDeleted() throws {
        let database = try Self.makeDatabase()
        let target = UUID(1)
        let other = UUID(2)
        try Self.seedWorkflow(database, workflowID: target)
        try Self.seedWorkflow(database, workflowID: other)
        try Self.seedReview(database, id: UUID(10), workflowID: target, kind: "security", status: "running")
        try Self.seedReview(database, id: UUID(11), workflowID: other, kind: "security", status: "running")
        try Self.seedReview(
            database, id: UUID(12), workflowID: target, kind: "code-quality", status: "running", isDeleted: true
        )

        try database.reconcileStaleRunningReviews(workflowID: target, now: Self.fixedDate)

        let rows = try database.read { db in try ReviewRow.fetchAll(db) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[UUID(10)]?.status == "failed")
        // The other Workflow's and the soft-deleted running reviews are left as-is.
        #expect(byID[UUID(11)]?.status == "running")
        #expect(byID[UUID(12)]?.status == "running")
    }

    // MARK: - SessionKind

    @Test func sessionKindHasValidate() {
        #expect(SessionKind.validate.rawValue == "validate")
        #expect(SessionKind.allCases.contains(.validate))
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

    private static func seedReview(
        _ database: any DatabaseWriter, id: UUID, workflowID: UUID, kind: String,
        status: String, isDeleted: Bool = false
    ) throws {
        try database.write { db in
            try ReviewRow.insert {
                ReviewRow(
                    id: id, workflowID: workflowID, kind: kind, status: status,
                    createdAt: fixedDate, updatedAt: fixedDate, isDeleted: isDeleted
                )
            }
            .execute(db)
        }
    }
}
