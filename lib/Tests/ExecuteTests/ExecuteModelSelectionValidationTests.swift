import Dependencies
import Foundation
import IssueGraph
import SQLiteData
import Store
import Testing

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("ExecuteModel selection & validation")
struct ExecuteModelSelectionValidationTests {

    // MARK: - Selection

    @Test("selectNode selects an unselected node and toggles it off when tapped again")
    func selectNodeToggles() throws {
        let model = try Self.makeModel()

        #expect(model.selectedID == nil)
        model.selectNode(2)
        #expect(model.selectedID == 2)
        model.selectNode(3)
        #expect(model.selectedID == 3)
        model.selectNode(3)
        #expect(model.selectedID == nil)
    }

    @Test("selectedIssue resolves the selected node to its committed Issue row")
    func selectedIssueResolves() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID, issues: [
            (1, "Root", [], "new"),
            (2, "Leaf", [1], "new"),
        ])
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        #expect(model.selectedIssue == nil)
        model.selectNode(2)
        #expect(model.selectedIssue?.number == 2)
        #expect(model.selectedIssue?.title == "Leaf")
    }

    // MARK: - Validation

    @Test("A valid DAG has no validation error and lays out normally")
    func validGraphHasNoError() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID, issues: [
            (1, "Root", [], "new"),
            (2, "Leaf", [1], "new"),
        ])
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        #expect(model.validationError == nil)
        #expect(model.validationMessage == nil)
        #expect(model.layoutNodes.count == 2)
    }

    @Test("An unknown dependency surfaces a validation error naming the offending Issues, and suppresses layout")
    func unknownDependencyValidationError() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID, issues: [
            (1, "Root", [], "new"),
            (2, "Bad ref", [99], "new"),
        ])
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        #expect(model.validationError == .unknownDependency(node: 2, dep: 99))
        let message = try #require(model.validationMessage)
        #expect(message.contains("#2"))
        #expect(message.contains("#99"))
        // Layout is suppressed so layeredLayout never runs on the invalid graph.
        #expect(model.layoutNodes.isEmpty)
    }

    @Test("A dependency cycle surfaces a cycle error naming the involved Issues, and suppresses layout")
    func cycleValidationError() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID, issues: [
            (1, "A", [2], "new"),
            (2, "B", [1], "new"),
        ])
        let model = Self.makeModel(database: database, workflowID: workflowID)
        try await model.$issues.load()

        #expect(model.validationError == .cycle(involving: [1, 2]))
        let message = try #require(model.validationMessage)
        #expect(message.contains("#1"))
        #expect(message.contains("#2"))
        #expect(model.layoutNodes.isEmpty)
    }

    // MARK: - Helpers

    private static func makeModel() throws -> ExecuteModel {
        let database = try makeDatabase()
        return makeModel(database: database, workflowID: UUID(0))
    }

    private static func makeModel(database: any DatabaseWriter, workflowID: UUID) -> ExecuteModel {
        withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database)
        }
    }

    private static func seed(
        _ database: any DatabaseWriter,
        workflowID: UUID,
        issues: [(Int, String, [Int], String)]
    ) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            for (number, title, deps, status) in issues {
                try IssueRow.insert {
                    IssueRow(
                        id: UUID(), workflowID: workflowID, number: number, title: title,
                        dependencies: deps, status: status, createdAt: fixedDate, updatedAt: fixedDate
                    )
                }
                .execute(db)
            }
        }
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
