import Dependencies
import Foundation
import SQLiteData
import Store
import Worktree

/// The root under which every Workflow directory lives: `~/.hercules/workflows/`.
public func defaultWorkflowsRoot() -> URL {
    URL.homeDirectory.appending(path: ".hercules/workflows")
}

/// Creates a new Workflow on disk for `repo`: a directory under `root`, an initialized per-Workflow
/// `Store` database, a `workflow` metadata row recording the repo path and creation time, and a git
/// worktree checked out on a fresh `hercules/<short-id>` branch under the Workflow directory.
/// Returns the value the `WorkflowContainer` window is opened with.
///
/// Creation is atomic: if the worktree can't be made (not a git repo, branch collision, etc.) the
/// Workflow directory and its database row are rolled back so no half-built Workflow is left behind.
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
        // Roll back the whole Workflow directory (which holds the database, and so the row) so a
        // failed worktree creation leaves nothing behind.
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }

    try? database.close()
    return WorkflowWindowData(id: id, directory: directory, repoPath: repo.path)
}

/// The deterministic worktree location for a Workflow: a `worktree/` subdirectory of its directory,
/// parallel to the per-Workflow database. A pure convention, not persisted.
public func workflowWorktree(in directory: URL) -> URL {
    directory.appending(component: "worktree")
}

/// The short, branch-friendly form of a Workflow id used in its `hercules/<short-id>` branch name.
private func shortID(for id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
}
