import Dependencies
import Foundation
import MCP
import SQLiteData
import Store
import Testing

@testable import IssueMCP

@Suite("ProposeIssue")
struct ProposeIssueTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The propose seam

    @Test func stampsProposedStatusAndHostAssignsTheNextNumber() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        // Allocate committed #1…#3; the next proposal must be #4.
        try Self.seedIssue(database, workflowID: workflowID, number: 1)
        try Self.seedIssue(database, workflowID: workflowID, number: 3)

        let row = try withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try proposeIssue(
                ProposeIssueArguments(title: "Extract origin parsing", body: "The spec."),
                workflowID: workflowID, into: database
            )
        }

        #expect(row.number == 4)
        #expect(row.status == "proposed")
        #expect(row.title == "Extract origin parsing")
        #expect(row.dependencies == [])
        #expect(row.workflowID == workflowID)
    }

    @Test func firstProposalInAnEmptyWorkflowIsNumberOne() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let row = try withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try proposeIssue(ProposeIssueArguments(title: "T", body: "B"), workflowID: workflowID, into: database)
        }

        #expect(row.number == 1)
    }

    @Test func numberingCountsSoftDeletedRowsSoDeniedNumbersAreNotReused() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)
        try Self.seedIssue(database, workflowID: workflowID, number: 1)
        // A previously-denied proposal, soft-deleted.
        try Self.seedIssue(database, workflowID: workflowID, number: 2, isDeleted: true)

        let row = try withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try proposeIssue(ProposeIssueArguments(title: "T", body: "B"), workflowID: workflowID, into: database)
        }

        #expect(row.number == 3)
    }

    @Test func concurrentProposalsGetDistinctNumbers() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let numbers = try await withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        try proposeIssue(
                            ProposeIssueArguments(title: "T\(i)", body: "B"),
                            workflowID: workflowID, into: database
                        ).number
                    }
                }
                var results: [Int] = []
                for try await number in group { results.append(number) }
                return results
            }
        }

        // Atomic max+insert in one write txn → eight distinct numbers, no collisions.
        #expect(Set(numbers).count == 8)
        #expect(Set(numbers) == Set(1...8))
    }

    // MARK: - Argument decoding

    @Test func decodesTitleAndBody() throws {
        let arguments = try ProposeIssueArguments(mcpArguments: [
            "title": .string("Fix the leak"),
            "body": .string("Close the handle."),
        ])
        #expect(arguments == ProposeIssueArguments(title: "Fix the leak", body: "Close the handle."))
    }

    @Test func malformedArgumentsThrow() {
        #expect(throws: (any Error).self) {
            try ProposeIssueArguments(mcpArguments: ["title": .string("only title")])
        }
        #expect(throws: (any Error).self) {
            try ProposeIssueArguments(mcpArguments: nil)
        }
    }

    // MARK: - Launch argument parsing

    @Test func proposeFlagSelectsTheProposeServer() {
        let config = IssueMCPLaunch.parse([
            "/path/to/Hercules", "--mcp-issue-server", "--propose",
            "--db", "/tmp/wf/workflow.sqlite", "--workflow-id", UUID(1).uuidString,
        ])
        #expect(config?.propose == true)
    }

    @Test func absentProposeFlagDefaultsToCreate() {
        let config = IssueMCPLaunch.parse([
            "/path/to/Hercules", "--mcp-issue-server",
            "--db", "/tmp/wf/workflow.sqlite", "--workflow-id", UUID(1).uuidString,
        ])
        #expect(config?.propose == false)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProposeIssueTests-\(UUID().uuidString)", isDirectory: true)
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
        _ database: any DatabaseWriter, workflowID: UUID, number: Int, isDeleted: Bool = false
    ) throws {
        try database.write { db in
            try IssueRow.insert {
                IssueRow(
                    id: UUID(), workflowID: workflowID, number: number, title: "Issue \(number)",
                    createdAt: fixedDate, updatedAt: fixedDate, isDeleted: isDeleted
                )
            }
            .execute(db)
        }
    }
}
