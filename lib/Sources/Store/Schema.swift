import Foundation
import SQLiteData
import StructuredQueries

// Per-Workflow SQLite schema. Each row type carries the sync-ready conventions from ADR 0003:
// a UUID primary key, `createdAt`/`updatedAt` timestamps, and an `isDeleted` soft-delete column.
// CloudKit sync is not enabled yet; the schema is merely shaped for it.

@Table("workflow")
public struct WorkflowRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var repoPath: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        repoPath: String = "",
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.repoPath = repoPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("phase")
public struct PhaseRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var workflowID: UUID
    public var kind: String
    public var status: String
    public var artifactPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        workflowID: UUID,
        kind: String,
        status: String,
        artifactPath: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.workflowID = workflowID
        self.kind = kind
        self.status = status
        self.artifactPath = artifactPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("session")
public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var workflowID: UUID
    public var worktreePath: String
    public var mode: String
    /// The surface this Session serves (Design/PRD/TestChat). Scopes a Chat's observation to its own
    /// Session's Turns; one Session per (workflowID, kind) (ADR 0005).
    public var kind: String
    /// The `number` of the Issue this Session worked, set only on `execute`-kind Sessions; `nil` for
    /// every chat surface. Links a behind-the-scenes Execute run back to its Issue so a failed Issue's
    /// transcript stays recoverable.
    public var issueNumber: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        workflowID: UUID,
        worktreePath: String,
        mode: String,
        kind: String,
        issueNumber: Int? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.workflowID = workflowID
        self.worktreePath = worktreePath
        self.mode = mode
        self.kind = kind
        self.issueNumber = issueNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("turn")
public struct TurnRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var userPrompt: String
    public var finalAnswer: String?
    public var isError: Bool
    public var durationMs: Int?
    public var costUSD: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        sessionID: UUID,
        userPrompt: String = "",
        finalAnswer: String? = nil,
        isError: Bool = false,
        durationMs: Int? = nil,
        costUSD: Double? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.userPrompt = userPrompt
        self.finalAnswer = finalAnswer
        self.isError = isError
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("issue")
public struct IssueRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var workflowID: UUID
    /// Per-Workflow 1…N number assigned by the agent during Allocate; `dependencies` reference these.
    public var number: Int
    public var title: String
    /// The bulk one-shot spec for the Issue.
    public var body: String
    /// The `number`s of the other Issues this one depends on, stored as a JSON array in a TEXT column.
    @Column(as: [Int].JSONRepresentation.self)
    public var dependencies: [Int]
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        workflowID: UUID,
        number: Int,
        title: String = "",
        body: String = "",
        dependencies: [Int] = [],
        status: String = "new",
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.workflowID = workflowID
        self.number = number
        self.title = title
        self.body = body
        self.dependencies = dependencies
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("content_block")
public struct ContentBlockRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var turnID: UUID
    public var position: Int
    public var role: String
    public var kind: String
    public var text: String
    /// The invoked tool's name, set only on `tool_use` blocks; `nil` for every other kind.
    public var toolName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        turnID: UUID,
        position: Int,
        role: String,
        kind: String,
        text: String = "",
        toolName: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.turnID = turnID
        self.position = position
        self.role = role
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}
