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

/// The outcome of ``deleteWorkflow(data:root:)``. The folder removal is the operation of record and
/// always runs, so the Workflow disappears regardless; ``gitCleanupError`` is non-nil when a git step
/// (worktree/branch removal or prune) failed, letting the caller show a brief non-blocking notice.
public struct DeleteWorkflowResult: Sendable {
    public let gitCleanupError: (any Error)?

    public init(gitCleanupError: (any Error)? = nil) {
        self.gitCleanupError = gitCleanupError
    }

    /// `true` when every git cleanup step succeeded.
    public var didGitCleanupSucceed: Bool { gitCleanupError == nil }
}

/// Tears down the Workflow identified by `data`, mirroring ``createWorkflow(repo:root:)``. The sequence
/// is: remove the git worktree and its dedicated `hercules/<short-id>` branch, `rm -rf` the Workflow
/// folder under `root` (its database and all Artifacts), then best-effort `git worktree prune` in the
/// repo. Folder removal is the operation of record: a git failure does not abort the teardown — the
/// folder is removed regardless and the failure is reported via ``DeleteWorkflowResult/gitCleanupError``
/// so the Workflow always disappears.
@discardableResult
public func deleteWorkflow(data: WorkflowWindowData, root: URL = defaultWorkflowsRoot()) -> DeleteWorkflowResult {
    @Dependency(\.worktreeClient) var worktreeClient

    let directory = root.appending(component: data.id.uuidString)
    let repo = URL(fileURLWithPath: data.repoPath)

    var gitCleanupError: (any Error)?

    // 1. Remove the git worktree and force-delete its dedicated branch.
    do {
        try worktreeClient.remove(
            RemoveWorktreeRequest(
                repo: repo,
                worktree: workflowWorktree(in: directory),
                branch: "hercules/\(shortID(for: data.id))"
            )
        )
    } catch {
        gitCleanupError = error
    }

    // 2. The operation of record: wipe the Workflow folder regardless of any git failure above.
    try? FileManager.default.removeItem(at: directory)

    // 3. Best-effort hygiene: prune any stale worktree entries left in the repo.
    do {
        try worktreeClient.prune(repo)
    } catch {
        // Keep the first git failure if there was one; otherwise surface the prune failure.
        if gitCleanupError == nil { gitCleanupError = error }
    }

    return DeleteWorkflowResult(gitCleanupError: gitCleanupError)
}

/// The deterministic worktree location: a `worktree/` subdirectory. A pure convention, not persisted.
public func workflowWorktree(in directory: URL) -> URL {
    directory.appending(component: "worktree")
}

private func shortID(for id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
}
