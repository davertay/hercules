import Dependencies
import Foundation
import SQLiteData
import Store
import Worktree

/// The root under which every Workflow directory lives: `~/.hercules/workflows/`.
public func defaultWorkflowsRoot() -> URL {
    URL.homeDirectory.appending(path: ".hercules/workflows")
}

/// Creates a Workflow for `repo`: a directory under `root`, its `Store` database, a `workflow` row, and
/// a git worktree on a fresh `hercules/<short-id>` branch. Atomic — a failed worktree creation rolls
/// back the directory and row so no half-built Workflow is left behind.
public func createWorkflow(repo: URL, root: URL = defaultWorkflowsRoot()) throws -> WorkflowWindowData {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now
    @Dependency(\.worktreeClient) var worktreeClient

    let id = uuid()
    let directory = root.appending(component: id.uuidString)
    let database = try openWorkflowDatabase(at: directory)

    let timestamp = now
    do {
        try database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: repo.path, createdAt: timestamp, updatedAt: timestamp)
            }
            .execute(db)
        }

        try worktreeClient.create(
            CreateWorktreeRequest(
                repo: repo,
                worktree: workflowWorktree(in: directory),
                branch: "hercules/\(shortID(for: id))"
            )
        )
    } catch {
        // Roll back the whole directory (which holds the database, and so the row).
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }

    try? database.close()
    return WorkflowWindowData(id: id, directory: directory, repoPath: repo.path)
}

/// The deterministic worktree location: a `worktree/` subdirectory. A pure convention, not persisted.
public func workflowWorktree(in directory: URL) -> URL {
    directory.appending(component: "worktree")
}

private func shortID(for id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
}
