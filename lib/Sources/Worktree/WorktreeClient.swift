import Dependencies
import DependenciesMacros
import Foundation

/// What a worktree creation needs: the source repository, the directory the new worktree should
/// live in, and the name of the new branch to cut for it.
public struct CreateWorktreeRequest: Sendable, Equatable {
    public let repo: URL
    public let worktree: URL
    public let branch: String

    public init(repo: URL, worktree: URL, branch: String) {
        self.repo = repo
        self.worktree = worktree
        self.branch = branch
    }
}

/// Provisions git worktrees for Workflows. Injected like ``AgentClient`` so the live value shells out
/// to git while the test and preview values are no-ops — that lets previews and tests build Workflows
/// against placeholder repo paths without touching git.
@DependencyClient
public struct WorktreeClient: Sendable {
    /// Adds a worktree for `request.repo` at `request.worktree`, checked out on a new branch named
    /// `request.branch` cut from the repo's default-branch HEAD. Throws if git fails (not a repo, the
    /// branch already exists, etc.).
    public var create: @Sendable (_ request: CreateWorktreeRequest) throws -> Void
}

extension WorktreeClient: DependencyKey {
    public static let liveValue = WorktreeClient(
        create: { request in
            let startPoint = try LiveGit.defaultBranch(in: request.repo)
            try LiveGit.run(
                ["-C", request.repo.path, "worktree", "add", "-b", request.branch, request.worktree.path, startPoint]
            )
        }
    )

    /// No-op so tests that create Workflows against placeholder repo paths don't touch git.
    public static let testValue = WorktreeClient(create: { _ in })

    /// No-op so previews that create Workflows against placeholder repo paths don't touch git.
    public static let previewValue = WorktreeClient(create: { _ in })
}

extension DependencyValues {
    public var worktreeClient: WorktreeClient {
        get { self[WorktreeClient.self] }
        set { self[WorktreeClient.self] = newValue }
    }
}

/// Surfaced when a git invocation exits non-zero; carries git's own stderr so the message is clear
/// (e.g. "fatal: a branch named 'hercules/…' already exists").
public struct GitError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(arguments.joined(separator: " ")) failed (status \(status)): \(detail)"
    }
}

/// The live git plumbing: synchronous `Process` invocations. Kept private to the live value — the
/// test and preview values never reach it.
private enum LiveGit {
    /// The repo's default branch, resolved from `origin/HEAD` when a remote exists and otherwise from
    /// the currently checked-out branch. Used as the start point so the new worktree gets a clean ref
    /// regardless of any uncommitted changes in the user's primary checkout.
    static func defaultBranch(in repo: URL) throws -> String {
        if let originHead = try? capture(
            ["-C", repo.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
        ) {
            return originHead.replacingOccurrences(of: "origin/", with: "")
        }
        return try capture(["-C", repo.path, "symbolic-ref", "--short", "HEAD"])
    }

    /// Runs git, throwing ``GitError`` on a non-zero exit.
    static func run(_ arguments: [String]) throws {
        _ = try capture(arguments)
    }

    /// Runs git and returns its trimmed stdout, throwing ``GitError`` on a non-zero exit.
    @discardableResult
    static func capture(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
