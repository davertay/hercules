import Dependencies
import Foundation
import SQLiteData
import Store

/// The root under which every Workflow directory lives: `~/.hercules/workflows/`.
public func defaultWorkflowsRoot() -> URL {
    URL.homeDirectory.appending(path: ".hercules/workflows")
}

/// Creates a new Workflow on disk for `repo`: a directory under `root`, an initialized per-Workflow
/// `Store` database, and a `workflow` metadata row recording the repo path and creation time.
/// Returns the value the `WorkflowContainer` window is opened with.
public func createWorkflow(repo: URL, root: URL = defaultWorkflowsRoot()) throws -> WorkflowWindowData {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now

    let id = uuid()
    let directory = root.appending(component: id.uuidString)
    let database = try openWorkflowDatabase(at: directory)
    defer { try? database.close() }

    let timestamp = now
    try database.write { db in
        try WorkflowRow.insert {
            WorkflowRow(id: id, repoPath: repo.path, createdAt: timestamp, updatedAt: timestamp)
        }
        .execute(db)
    }

    return WorkflowWindowData(id: id, directory: directory, repoPath: repo.path)
}
