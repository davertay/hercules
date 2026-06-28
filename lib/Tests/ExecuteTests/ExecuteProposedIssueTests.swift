import Dependencies
import Foundation
import IssueGraph
import SQLiteData
import Store
import Testing

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("ExecuteModel — Proposed Issues")
struct ExecuteProposedIssueTests {

    @Test("A proposed Issue renders as a .proposed node, distinct from ready")
    func proposedNodeIsDistinct() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedProposed(database, workflowID: workflowID, number: 8)

        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        #expect(model.nodesByNumber[8]?.status == .proposed)
    }

    @Test("Approve flips the proposed Issue to ready (new + no deps)")
    func approveMakesItReady() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedProposed(database, workflowID: workflowID, number: 8)
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        model.approve(8)
        try await model.$issues.load()

        #expect(model.nodesByNumber[8]?.status == .ready)
        let row = try #require(try Self.issue(database, workflowID: workflowID, number: 8))
        #expect(row.status == "new")
    }

    @Test("Deny removes the proposed Issue from the graph and clears its selection")
    func denyRemovesAndClearsSelection() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seedProposed(database, workflowID: workflowID, number: 8)
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()
        model.selectNode(8)
        #expect(model.selectedID == 8)

        model.deny(8)
        try await model.$issues.load()

        #expect(model.selectedID == nil)
        #expect(model.nodesByNumber[8] == nil)
        let row = try #require(try Self.issue(database, workflowID: workflowID, number: 8))
        #expect(row.isDeleted == true)
    }

    // MARK: - Helpers

    private static func makeModel(database: any DatabaseWriter, workflowID: UUID) -> ExecuteModel {
        withDependencies {
            $0.defaultDatabase = database
            $0.date.now = fixedDate
        } operation: {
            ExecuteModel(
                workflowID: workflowID, database: database,
                worktree: FileManager.default.temporaryDirectory,
                workflowDirectory: FileManager.default.temporaryDirectory
            )
        }
    }

    private static func seedProposed(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Proposed fix",
                    body: "The spec.", status: "proposed", createdAt: fixedDate, updatedAt: fixedDate
                )
            }
            .execute(db)
        }
    }

    private static func issue(
        _ database: any DatabaseWriter, workflowID: UUID, number: Int
    ) throws -> IssueRow? {
        try database.read { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) && $0.number.eq(number) }
                .fetchOne(db)
        }
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteProposedIssueTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
