import Foundation
import SQLiteData
import Store

/// An existing Workflow discovered on disk, for the launcher's "open existing" list.
public struct WorkflowSummary: Identifiable, Hashable, Sendable {
    public var data: WorkflowWindowData
    public var workflowTitle: String
    public var createdAt: Date

    public var id: UUID { data.id }

    /// The repo name plus the user-editable title, matching the open window's title bar.
    public var title: String {
        workflowListingDisplayTitle(repoPath: data.repoPath, title: workflowTitle)
    }
}

/// Enumerates the Workflows under `root` (`~/.hercules/workflows/` by default), newest first. Each
/// directory holds its own `workflow.sqlite`; we open each, read its single non-deleted `workflow` row,
/// and skip anything unreadable rather than failing the whole list. Migrations are idempotent, so opening
/// is safe on an already-migrated file.
public func listWorkflows(root: URL = defaultWorkflowsRoot()) -> [WorkflowSummary] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
        return []
    }

    var summaries: [WorkflowSummary] = []
    for directory in entries {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(atPath: directory.appendingPathComponent("workflow.sqlite").path)
        else { continue }

        guard let database = try? openWorkflowDatabase(at: directory) else { continue }
        defer { try? database.close() }

        let row = try? database.read { db in
            try WorkflowRow.where { !$0.isDeleted }.fetchOne(db)
        }
        guard let row else { continue }

        summaries.append(
            WorkflowSummary(
                data: WorkflowWindowData(
                    id: row.id,
                    directory: directory,
                    repoPath: row.repoPath
                ),
                workflowTitle: row.title,
                createdAt: row.createdAt
            )
        )
    }

    return summaries.sorted { $0.createdAt > $1.createdAt }
}
