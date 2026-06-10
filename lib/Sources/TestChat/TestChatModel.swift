import Agent
import Dependencies
import Foundation
import Observation
import SQLiteData
import Store

@MainActor
@Observable
public final class TestChatModel {
    struct ChatMessage: Identifiable, Sendable {
        let id: UUID
        enum Role: Sendable { case user, assistant }
        let role: Role
        let text: String
        let isError: Bool

        init(role: Role, text: String, isError: Bool = false) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.isError = isError
        }
    }

    @ObservationIgnored
    @Dependency(\.agentClient) var agentClient: AgentClient

    @ObservationIgnored
    private let teardown: TeardownHandle

    @ObservationIgnored
    private let workflowID = UUID()

    private var session: Session?

    var isRunning = false
    var draftText = ""
    var messages: [ChatMessage] = []

    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        // One disposable Workflow database under the temp root. The connection is owned by the
        // TeardownHandle so it can be closed before the directory is unlinked on close.
        let database = try? openWorkflowDatabase(at: storageRoot)
        if let database {
            let now = Date()
            let workflowID = workflowID
            try? database.write { db in
                try WorkflowRow.insert {
                    WorkflowRow(id: workflowID, repoPath: worktree.path, createdAt: now, updatedAt: now)
                }
                .execute(db)
            }
        }
        self.teardown = TeardownHandle(storageRoot: storageRoot, database: database)
    }

    private var database: (any DatabaseWriter)? { teardown.database }

    // Exposed internally so tests can assert the connection is closed before the storage is
    // removed (it must be, or libsqlite3 warns "vnode unlinked while in use").
    var databaseForTesting: (any DatabaseWriter)? { teardown.database }

    // Exposed internally so tests can observe cleanup without publishing it as API.
    var storageRoot: URL { teardown.storageRoot }

    var windowTitle: String {
        "Test Chat: \(worktree.lastPathComponent)"
    }

    var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning
    }

    func submit() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        guard let database else {
            messages.append(ChatMessage(role: .assistant, text: "Workflow store unavailable.", isError: true))
            return
        }
        draftText = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        isRunning = true
        teardown.runTask = Task {
            do {
                let completedSession: Session
                if let existing = session {
                    completedSession = try await agentClient.send(
                        SendRequest(prompt: prompt, session: existing, database: database)
                    )
                } else {
                    completedSession = try await agentClient.start(
                        StartRequest(
                            prompt: prompt,
                            worktree: worktree,
                            mode: .readOnly,
                            database: database,
                            workflowID: workflowID,
                            kind: .testChat
                        )
                    )
                    session = completedSession
                }
                messages = rebuildMessages(for: completedSession.id, database: database)
            } catch {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    isError: true
                ))
            }
            isRunning = false
        }
    }

    func tearDown() {
        teardown.cleanup()
    }

    /// Reconstructs the conversation from the Workflow database: one user bubble per Turn's prompt,
    /// paired with that Turn's final answer (or an error marker for a failed Turn).
    private func rebuildMessages(for sessionID: Session.ID, database: any DatabaseWriter) -> [ChatMessage] {
        let turns = (try? database.read { db in try TurnRow.fetchAll(db) }) ?? []
        let ordered = turns
            .filter { $0.sessionID == sessionID.rawValue }
            .sorted { $0.createdAt < $1.createdAt }

        var rebuilt: [ChatMessage] = []
        for turn in ordered {
            rebuilt.append(ChatMessage(role: .user, text: turn.userPrompt))
            if let answer = turn.finalAnswer, !answer.isEmpty {
                rebuilt.append(ChatMessage(role: .assistant, text: answer, isError: turn.isError))
            } else if turn.isError {
                rebuilt.append(ChatMessage(role: .assistant, text: "Turn failed.", isError: true))
            }
        }
        return rebuilt.isEmpty ? messages : rebuilt
    }
}

// Holds cleanup state so that deinit can cancel the in-flight task and remove
// the storage directory even if tearDown() was never called (missed signal).
// @unchecked Sendable: mutation is confined to @MainActor; deinit runs after
// the last strong reference drops, at which point no @MainActor code can reach
// these fields.
private final class TeardownHandle: @unchecked Sendable {
    var runTask: Task<Void, Never>?
    let storageRoot: URL
    let database: (any DatabaseWriter)?

    init(storageRoot: URL, database: (any DatabaseWriter)?) {
        self.storageRoot = storageRoot
        self.database = database
    }

    // Close the SQLite connection *before* unlinking the directory. Otherwise libsqlite3
    // reports "vnode unlinked while in use" because the open file descriptors (db, -wal, -shm)
    // outlive the file. Idempotent: a second cleanup() finds the connection already closed and
    // the directory already gone.
    func cleanup() {
        runTask?.cancel()
        runTask = nil
        try? database?.close()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    deinit {
        cleanup()
    }
}
