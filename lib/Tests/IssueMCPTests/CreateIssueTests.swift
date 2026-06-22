import Dependencies
import Foundation
import MCP
import SQLiteData
import Store
import Testing

@testable import IssueMCP

@Suite("CreateIssue")
struct CreateIssueTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The insert seam

    @Test func insertsIssueRowFromArguments() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(1)
        try Self.seedWorkflow(database, workflowID: workflowID)

        let arguments = CreateIssueArguments(
            number: 7, title: "Add issue table", body: "The bulk spec.", dependencies: [3, 5]
        )

        let inserted = try withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try createIssue(arguments, workflowID: workflowID, into: database)
        }

        let row = try #require(try database.read { db in try IssueRow.fetchOne(db) })
        #expect(row.number == 7)
        #expect(row.title == "Add issue table")
        #expect(row.body == "The bulk spec.")
        #expect(row.dependencies == [3, 5])
        // workflowID from the launch context, status defaulted, id/timestamps from deps.
        #expect(row.workflowID == workflowID)
        #expect(row.status == "new")
        #expect(row.id == UUID(0))
        #expect(row.createdAt == Self.fixedDate)
        #expect(row.updatedAt == Self.fixedDate)
        #expect(inserted == row)
    }

    @Test func ignoresAnyWorkflowIDInArguments() throws {
        // `workflowID` isn't a decoded field, so an extra key in the raw arguments can't override the
        // launch one.
        let database = try Self.makeDatabase()
        let launchWorkflow = UUID(1)
        try Self.seedWorkflow(database, workflowID: launchWorkflow)

        let arguments = try CreateIssueArguments(mcpArguments: [
            "number": .int(1),
            "title": .string("T"),
            "body": .string("B"),
            "workflowID": .string(UUID(99).uuidString),
        ])

        try withDependencies {
            $0.uuid = .incrementing
            $0.date.now = Self.fixedDate
        } operation: {
            try createIssue(arguments, workflowID: launchWorkflow, into: database)
        }

        let row = try #require(try database.read { db in try IssueRow.fetchOne(db) })
        #expect(row.workflowID == launchWorkflow)
    }

    // MARK: - Argument decoding

    @Test func decodesArgumentsFromMCPValues() throws {
        let arguments = try CreateIssueArguments(mcpArguments: [
            "number": .int(4),
            "title": .string("Title"),
            "body": .string("Body"),
            "dependencies": .array([.int(1), .int(2)]),
        ])
        #expect(arguments == CreateIssueArguments(
            number: 4, title: "Title", body: "Body", dependencies: [1, 2]
        ))
    }

    @Test func defaultsDependenciesWhenOmitted() throws {
        let arguments = try CreateIssueArguments(mcpArguments: [
            "number": .int(1), "title": .string("T"), "body": .string("B"),
        ])
        #expect(arguments.dependencies == [])
    }

    @Test func malformedArgumentsThrow() {
        // Missing the required `number` field.
        #expect(throws: (any Error).self) {
            try CreateIssueArguments(mcpArguments: [
                "title": .string("T"), "body": .string("B"),
            ])
        }
        // Wrong type for `number`.
        #expect(throws: (any Error).self) {
            try CreateIssueArguments(mcpArguments: [
                "number": .string("not a number"), "title": .string("T"), "body": .string("B"),
            ])
        }
        // No arguments at all.
        #expect(throws: (any Error).self) {
            try CreateIssueArguments(mcpArguments: nil)
        }
    }

    // MARK: - Launch argument parsing

    @Test func parsesSubcommandArguments() {
        let config = IssueMCPLaunch.parse([
            "/path/to/Hercules", "--mcp-issue-server",
            "--db", "/tmp/wf/workflow.sqlite",
            "--workflow-id", UUID(1).uuidString,
        ])
        #expect(config == IssueMCPLaunch.Configuration(
            databasePath: "/tmp/wf/workflow.sqlite", workflowID: UUID(1)
        ))
    }

    @Test func returnsNilWithoutSubcommand() {
        #expect(IssueMCPLaunch.parse(["/path/to/Hercules"]) == nil)
        #expect(IssueMCPLaunch.parse([
            "/path/to/Hercules", "--db", "/tmp/wf/workflow.sqlite",
            "--workflow-id", UUID(1).uuidString,
        ]) == nil)
    }

    @Test func returnsNilWhenOperandsMissingOrInvalid() {
        // Missing --db.
        #expect(IssueMCPLaunch.parse([
            "--mcp-issue-server", "--workflow-id", UUID(1).uuidString,
        ]) == nil)
        // Invalid workflow id.
        #expect(IssueMCPLaunch.parse([
            "--mcp-issue-server", "--db", "/tmp/wf/workflow.sqlite", "--workflow-id", "not-a-uuid",
        ]) == nil)
    }

    // MARK: - Helpers

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueMCPTests-\(UUID().uuidString)", isDirectory: true)
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
}
