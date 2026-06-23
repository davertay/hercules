import Dependencies
import Foundation
import MCP
import SQLiteData
import Store

// The seam below the MCP transport, driven directly by tests without real stdio.

/// `dependencies` defaults to empty when the model omits it.
public struct CreateIssueArguments: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var body: String
    public var dependencies: [Int]

    public init(number: Int, title: String, body: String, dependencies: [Int] = []) {
        self.number = number
        self.title = title
        self.body = body
        self.dependencies = dependencies
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, body, dependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        dependencies = try container.decodeIfPresent([Int].self, forKey: .dependencies) ?? []
    }

    /// Throws when a required field is missing or the wrong type — reported back as a tool error.
    public init(mcpArguments: [String: Value]?) throws {
        let data = try JSONEncoder().encode(Value.object(mcpArguments ?? [:]))
        self = try JSONDecoder().decode(CreateIssueArguments.self, from: data)
    }
}

/// The `propose_issue` tool's arguments: a HITL fix proposal carries only title + body. The number is
/// host-assigned and the status is fixed (`proposed`), so neither is part of the model's input.
public struct ProposeIssueArguments: Codable, Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// Throws when a required field is missing or the wrong type — reported back as a tool error.
    public init(mcpArguments: [String: Value]?) throws {
        let data = try JSONEncoder().encode(Value.object(mcpArguments ?? [:]))
        self = try JSONDecoder().decode(ProposeIssueArguments.self, from: data)
    }
}

/// Status raw values stamped on inserted Issues. `proposed` is a HITL fix awaiting approval; Execute's run
/// loop only picks `new`, so a proposed Issue is inert until approved.
public let newIssueStatus = "new"
public let proposedIssueStatus = "proposed"

/// `workflowID` comes from the launch context, not the arguments, so the model can't target another
/// Workflow. Allocate's `create_issue` — the model assigns the `number` and the status is `new`.
@discardableResult
public func createIssue(
    _ arguments: CreateIssueArguments,
    workflowID: UUID,
    into database: any DatabaseWriter
) throws -> IssueRow {
    try insertIssue(
        workflowID: workflowID,
        number: arguments.number,
        title: arguments.title,
        body: arguments.body,
        dependencies: arguments.dependencies,
        status: newIssueStatus,
        into: database
    )
}

/// Validate's `propose_issue` — the host stamps `proposed` and assigns the next number atomically, so
/// concurrent reviews can't collide on a number.
@discardableResult
public func proposeIssue(
    _ arguments: ProposeIssueArguments,
    workflowID: UUID,
    into database: any DatabaseWriter
) throws -> IssueRow {
    try insertIssue(
        workflowID: workflowID,
        number: nil,
        title: arguments.title,
        body: arguments.body,
        dependencies: [],
        status: proposedIssueStatus,
        into: database
    )
}

/// The shared insert core. A `nil` `number` is host-assigned as `max(existing) + 1` within the same write
/// transaction as the insert, so two concurrent `proposeIssue` calls (separate server processes sharing
/// the DB) serialise on SQLite's single writer and can't pick the same number.
@discardableResult
func insertIssue(
    workflowID: UUID,
    number: Int?,
    title: String,
    body: String,
    dependencies: [Int],
    status: String,
    into database: any DatabaseWriter
) throws -> IssueRow {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now

    return try database.write { db in
        let resolvedNumber: Int
        if let number {
            resolvedNumber = number
        } else {
            // Over every row including soft-deleted ones, so a denied (soft-deleted) proposal's number is
            // never reused.
            let existing = try IssueRow.where { $0.workflowID.eq(workflowID) }.fetchAll(db)
            resolvedNumber = (existing.map(\.number).max() ?? 0) + 1
        }
        let row = IssueRow(
            id: uuid(),
            workflowID: workflowID,
            number: resolvedNumber,
            title: title,
            body: body,
            dependencies: dependencies,
            status: status,
            createdAt: now,
            updatedAt: now
        )
        try IssueRow.insert { row }.execute(db)
        return row
    }
}
