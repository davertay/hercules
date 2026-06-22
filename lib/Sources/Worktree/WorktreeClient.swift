import Dependencies
import DependenciesMacros
import Foundation

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

/// Provisions git worktrees for Workflows. The live value shells out to git; test and preview values
/// are no-ops so they can build Workflows against placeholder repo paths without touching git.
@DependencyClient
public struct WorktreeClient: Sendable {
    /// Adds a worktree on a new branch cut from the repo's default-branch HEAD.
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

    public static let testValue = WorktreeClient(create: { _ in })

    public static let previewValue = WorktreeClient(create: { _ in })
}

extension DependencyValues {
    public var worktreeClient: WorktreeClient {
        get { self[WorktreeClient.self] }
        set { self[WorktreeClient.self] = newValue }
    }
}

/// Carries git's own stderr so the message is clear (e.g. "fatal: a branch named '…' already exists").
public struct GitError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(arguments.joined(separator: " ")) failed (status \(status)): \(detail)"
    }
}

private enum LiveGit {
    /// Resolved from `origin/HEAD` when a remote exists, else the checked-out branch. The start point
    /// so the new worktree gets a clean ref regardless of uncommitted changes in the primary checkout.
    static func defaultBranch(in repo: URL) throws -> String {
        if let originHead = try? capture(
            ["-C", repo.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
        ) {
            return originHead.replacingOccurrences(of: "origin/", with: "")
        }
        return try capture(["-C", repo.path, "symbolic-ref", "--short", "HEAD"])
    }

    static func run(_ arguments: [String]) throws {
        _ = try capture(arguments)
    }

    /// Returns git's trimmed stdout, throwing ``GitError`` on a non-zero exit.
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
