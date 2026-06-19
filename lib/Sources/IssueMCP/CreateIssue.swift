import Dependencies
import Foundation
import MCP
import SQLiteData
import Store

// The seam below the MCP transport: decode the model-supplied `create_issue` arguments and insert a
// single `IssueRow`. The model supplies content only — the `workflowID` is fixed by the launch
// context (never an argument), `status` is always `"new"`, and the id/timestamps come from the
// injected `uuid`/`date` dependencies. Tests drive these functions directly, without real stdio.

/// The decoded arguments of one `create_issue` tool call: the content the model supplies for an
/// Issue. `dependencies` defaults to empty when the model omits it for an Issue with no dependencies.
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

    /// Decodes the arguments out of the raw MCP `[String: Value]` map a `tools/call` carries. Throws
    /// when a required field (`number`, `title`, `body`) is missing or the wrong type — the malformed
    /// path the server reports back as a tool error.
    public init(mcpArguments: [String: Value]?) throws {
        let data = try JSONEncoder().encode(Value.object(mcpArguments ?? [:]))
        self = try JSONDecoder().decode(CreateIssueArguments.self, from: data)
    }
}

/// Inserts one `IssueRow` from decoded `create_issue` arguments into `database`. The `workflowID`
/// comes from the launch context (not the arguments) so the model can never target another Workflow;
/// `status` is `"new"`; the id and timestamps are taken from the injected `uuid`/`date` dependencies.
@discardableResult
public func createIssue(
    _ arguments: CreateIssueArguments,
    workflowID: UUID,
    into database: any DatabaseWriter
) throws -> IssueRow {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now

    let row = IssueRow(
        id: uuid(),
        workflowID: workflowID,
        number: arguments.number,
        title: arguments.title,
        body: arguments.body,
        dependencies: arguments.dependencies,
        status: "new",
        createdAt: now,
        updatedAt: now
    )
    try database.write { db in
        try IssueRow.insert { row }.execute(db)
    }
    return row
}
