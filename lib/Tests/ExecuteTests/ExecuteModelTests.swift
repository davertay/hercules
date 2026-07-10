import Dependencies
import Foundation
import IssueGraph
import SQLiteData
import Store
import Testing

@testable import Execute

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
@Suite("ExecuteModel")
struct ExecuteModelTests {

    @Test("Starts empty before any Issues are loaded")
    func startsEmpty() throws {
        let database = try Self.makeDatabase()
        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: UUID(0), database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        #expect(model.isEmpty)
        #expect(model.nodes.isEmpty)
    }

    @Test("Observes the Workflow's committed Issues and projects them into a laid-out DAG")
    func observesIssuesAndProjectsDAG() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID)

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }
        try await model.$issues.load()

        #expect(!model.isEmpty)
        #expect(model.nodes.count == 3)

        let byNumber = model.nodesByNumber
        // #1 is a root → ready; #2 depends on the not-done #1 → pending; #3 likewise.
        #expect(byNumber[1]?.status == .ready)
        #expect(byNumber[2]?.status == .pending)
        // The layout places the root above its dependents.
        let layout = Dictionary(uniqueKeysWithValues: model.layoutNodes.map { ($0.id, $0) })
        #expect(layout[1]?.y == 0)
        #expect(layout[2]?.y == 1)
        #expect(layout[3]?.y == 2)
    }

    @Test("Excludes soft-deleted Issues")
    func excludesSoftDeletedIssues() async throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try Self.seed(database, workflowID: workflowID)
        try await database.write { db in
            try IssueRow
                .where { $0.workflowID.eq(workflowID) && $0.number.eq(3) }
                .update { $0.isDeleted = true }
                .execute(db)
        }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }
        try await model.$issues.load()

        #expect(model.nodes.count == 2)
        #expect(model.nodesByNumber[3] == nil)
    }

    @Test("Reports a healthy worktree when the directory exists on disk")
    func worktreePresent() throws {
        let database = try Self.makeDatabase()
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteWorktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: UUID(0), database: database, worktree: worktree, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        #expect(!model.worktreeMissing)
        #expect(model.worktreeMessage == nil)
    }

    @Test("Surfaces a missing-worktree error when the directory is absent (e.g. externally pruned)")
    func worktreeMissing() throws {
        let database = try Self.makeDatabase()
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteWorktree-\(UUID().uuidString)", isDirectory: true)

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: UUID(0), database: database, worktree: worktree, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        #expect(model.worktreeMissing)
        #expect(model.worktreeMessage?.contains(worktree.path) == true)
    }

    @Test("Resolves the last-turn answer for a done Issue, and nil for not-done or answerless Issues")
    func lastTurnAnswerResolvesForDoneIssuesOnly() throws {
        let database = try Self.makeDatabase()
        let workflowID = UUID(0)
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            // Every case gets a real execute run seeded, so the resolver's verdict turns on status and
            // the answer alone — not on missing data.
            try Self.seedRun(db, workflowID: workflowID, issueNumber: 1, finalAnswer: "All wired up.")
            try Self.seedRun(db, workflowID: workflowID, issueNumber: 2, finalAnswer: "Still going.")
            try Self.seedRun(db, workflowID: workflowID, issueNumber: 3, finalAnswer: nil)
            try Self.seedRun(db, workflowID: workflowID, issueNumber: 4, finalAnswer: "")
        }

        let model = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ExecuteModel(workflowID: workflowID, database: database, worktree: FileManager.default.temporaryDirectory, workflowDirectory: FileManager.default.temporaryDirectory)
        }

        func issue(_ number: Int, _ status: IssueRunStatus) -> IssueRow {
            IssueRow(id: UUID(), workflowID: workflowID, number: number, status: status.rawValue,
                     createdAt: fixedDate, updatedAt: fixedDate)
        }

        // Done with a non-empty answer → the answer surfaces.
        #expect(model.lastTurnAnswer(for: issue(1, .done)) == "All wired up.")
        // Not done (even with an answer) → nil; the failure/in-progress inspector is untouched.
        #expect(model.lastTurnAnswer(for: issue(2, .inProgress)) == nil)
        // Done but the run left no answer (nil, then empty) → nil, so the body-only inspector stands.
        #expect(model.lastTurnAnswer(for: issue(3, .done)) == nil)
        #expect(model.lastTurnAnswer(for: issue(4, .done)) == nil)
        // Done but never ran (no Session) → nil.
        #expect(model.lastTurnAnswer(for: issue(5, .done)) == nil)
    }

    /// Seeds an `execute` Session for `issueNumber` and one Turn carrying `finalAnswer`, the shape
    /// `lastTurnAnswer(for:)` reads back through `session(forIssue:)` + `latestTurnFinalAnswer`.
    private static func seedRun(
        _ db: Database, workflowID: UUID, issueNumber: Int, finalAnswer: String?
    ) throws {
        let sessionID = UUID()
        try SessionRow.insert {
            SessionRow(
                id: sessionID, workflowID: workflowID, worktreePath: "/worktree",
                mode: "write", kind: SessionKind.execute.rawValue, issueNumber: issueNumber,
                createdAt: fixedDate, updatedAt: fixedDate
            )
        }
        .execute(db)
        try TurnRow.insert {
            TurnRow(
                id: UUID(), sessionID: sessionID, finalAnswer: finalAnswer,
                createdAt: fixedDate, updatedAt: fixedDate
            )
        }
        .execute(db)
    }

    private static func seed(_ database: any DatabaseWriter, workflowID: UUID) throws {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: workflowID, repoPath: "/repo", createdAt: fixedDate, updatedAt: fixedDate)
            }
            .execute(db)
            let issues: [IssueRow] = [
                IssueRow(id: UUID(), workflowID: workflowID, number: 1, title: "Root",
                         dependencies: [], createdAt: fixedDate, updatedAt: fixedDate),
                IssueRow(id: UUID(), workflowID: workflowID, number: 2, title: "Middle",
                         dependencies: [1], createdAt: fixedDate, updatedAt: fixedDate),
                IssueRow(id: UUID(), workflowID: workflowID, number: 3, title: "Leaf",
                         dependencies: [2], createdAt: fixedDate, updatedAt: fixedDate),
            ]
            for issue in issues {
                try IssueRow.insert { issue }.execute(db)
            }
        }
    }

    private static func makeDatabase() throws -> any DatabaseWriter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecuteTests-\(UUID().uuidString)", isDirectory: true)
        return try openWorkflowDatabase(at: dir)
    }
}
