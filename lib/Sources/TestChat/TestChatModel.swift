import Agent
import Chat
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

@MainActor
@Observable
public final class TestChatModel {
    let engine: ChatEngine

    @ObservationIgnored
    private let teardown: TeardownHandle

    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
        let workflowID = UUID()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        // Disposable database in temp storage. Creation in a temp dir is treated as infallible.
        let database: any DatabaseWriter
        do {
            database = try openWorkflowDatabase(at: storageRoot)
            let now = Date()
            try database.write { db in
                try WorkflowRow.insert {
                    WorkflowRow(id: workflowID, repoPath: worktree.path, createdAt: now, updatedAt: now)
                }
                .execute(db)
            }
        } catch {
            fatalError("TestChat: failed to create disposable database: \(error)")
        }

        self.teardown = TeardownHandle(storageRoot: storageRoot, database: database)
        // Scope `defaultDatabase` so the engine's @Fetch observes this disposable store.
        self.engine = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            ChatEngine(
                worktree: worktree,
                mode: .readOnly,
                workflowID: workflowID,
                kind: .testChat,
                database: database
            )
        }
    }

    var databaseForTesting: (any DatabaseWriter)? { teardown.database }

    var storageRoot: URL { teardown.storageRoot }

    public var windowTitle: String {
        "Test Chat: \(worktree.lastPathComponent)"
    }

    public func tearDown() {
        engine.runTask?.cancel()
        teardown.cleanup()
    }
}

// Holds the disposable database/storage so deinit can close and unlink them if tearDown() never ran.
// @unchecked Sendable: mutation is confined to @MainActor; deinit runs after the last reference drops.
private final class TeardownHandle: @unchecked Sendable {
    let storageRoot: URL
    let database: (any DatabaseWriter)?

    init(storageRoot: URL, database: (any DatabaseWriter)?) {
        self.storageRoot = storageRoot
        self.database = database
    }

    // Close the connection *before* unlinking, or libsqlite3 warns "vnode unlinked while in use".
    // Idempotent.
    func cleanup() {
        try? database?.close()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    deinit {
        cleanup()
    }
}
