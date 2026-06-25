import Foundation
import SQLiteData
import StructuredQueries

// Per-Workflow SQLite schema. Each row carries the sync-ready conventions from ADR 0003 (UUID PK,
// timestamps, `isDeleted`); CloudKit sync is not enabled yet, the schema is merely shaped for it.

@Table("workflow")
public struct WorkflowRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var repoPath: String
    /// The user-editable title. Empty means unnamed; the UI falls back to the bare repo name.
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        repoPath: String = "",
        title: String = "",
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.repoPath = repoPath
        self.title = title
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
    /// The surface this Session serves; one Session per (workflowID, kind) (ADR 0005).
    public var kind: String
    /// Set only on `execute`-kind Sessions, linking the run back to its Issue; `nil` for chat surfaces.
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
    /// Why the last Execute run of this Issue failed; `nil` unless `status` is `failed`. Captured even
    /// when the agent throws before any `turn` row exists (e.g. the harness binary can't be found).
    public var failureReason: String?
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
        failureReason: String? = nil,
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
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

@Table("review")
public struct ReviewRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var workflowID: UUID
    /// The review Persona this row belongs to (`ReviewPersona` rawValue); one row per (workflowID, kind),
    /// upserted on each run — no run history.
    public var kind: String
    public var status: String
    /// The Persona's captured Summary; set on `reviewed`, `nil` otherwise.
    public var summary: String?
    /// Why the last run of this Persona failed; `nil` unless `status` is `failed`.
    public var failureReason: String?
    /// Forward link to the run's Session, for a future transcript viewer; `nil` until the run records one.
    public var sessionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        workflowID: UUID,
        kind: String,
        status: String,
        summary: String? = nil,
        failureReason: String? = nil,
        sessionID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.workflowID = workflowID
        self.kind = kind
        self.status = status
        self.summary = summary
        self.failureReason = failureReason
        self.sessionID = sessionID
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
