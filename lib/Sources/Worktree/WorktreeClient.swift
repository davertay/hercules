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
    /// Pushes the worktree's current branch to `origin` with upstream tracking (`git push -u origin
    /// <branch>`), so the branch exists on GitHub for a PR.
    public var push: @Sendable (_ worktree: URL) throws -> Void
    /// The GitHub compare URL for opening a PR from the worktree's branch against the default base,
    /// deriving owner/repo from `origin` (ssh or https).
    public var compareURL: @Sendable (_ worktree: URL) throws -> URL
}

extension WorktreeClient: DependencyKey {
    public static let liveValue = WorktreeClient(
        create: { request in
            let startPoint = try LiveGit.defaultBranch(in: request.repo)
            try LiveGit.run(
                ["-C", request.repo.path, "worktree", "add", "-b", request.branch, request.worktree.path, startPoint]
            )
        },
        push: { worktree in
            let branch = try LiveGit.currentBranch(in: worktree)
            try LiveGit.run(["-C", worktree.path, "push", "-u", "origin", branch])
        },
        compareURL: { worktree in
            let branch = try LiveGit.currentBranch(in: worktree)
            let base = try LiveGit.defaultBranch(in: worktree)
            let remote = try LiveGit.capture(["-C", worktree.path, "remote", "get-url", "origin"])
            guard let url = gitHubCompareURL(remote: remote, base: base, branch: branch) else {
                throw WorktreeError.unsupportedRemote(remote)
            }
            return url
        }
    )

    public static let testValue = WorktreeClient(
        create: { _ in },
        push: { _ in },
        compareURL: { _ in URL(string: "https://github.com/owner/repo/compare/main...branch?expand=1")! }
    )

    public static let previewValue = WorktreeClient(
        create: { _ in },
        push: { _ in },
        compareURL: { _ in URL(string: "https://github.com/owner/repo/compare/main...branch?expand=1")! }
    )
}

/// Builds the GitHub compare URL (`.../compare/<base>...<branch>?expand=1`) that pre-fills a PR, deriving
/// `owner/repo` from an `origin` remote in either ssh (`git@github.com:owner/repo.git`) or https
/// (`https://github.com/owner/repo.git`) form. Returns `nil` when the remote isn't a recognised GitHub URL.
public func gitHubCompareURL(remote: String, base: String, branch: String) -> URL? {
    guard let slug = gitHubSlug(from: remote) else { return nil }
    return URL(string: "https://github.com/\(slug)/compare/\(base)...\(branch)?expand=1")
}

/// Extracts the `owner/repo` slug from a GitHub remote URL, tolerating ssh/https/git schemes and a
/// trailing `.git`.
func gitHubSlug(from remote: String) -> String? {
    var string = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if string.hasSuffix(".git") { string = String(string.dropLast(4)) }
    // ssh shorthand `git@github.com:owner/repo`, or any scheme ending `github.com/owner/repo`.
    for separator in ["github.com:", "github.com/"] {
        if let range = string.range(of: separator) {
            let slug = String(string[range.upperBound...])
            return slug.isEmpty ? nil : slug
        }
    }
    return nil
}

public enum WorktreeError: Error, LocalizedError, CustomStringConvertible {
    case unsupportedRemote(String)

    public var description: String {
        switch self {
        case .unsupportedRemote(let remote):
            "The `origin` remote isn't a recognised GitHub URL, so a compare URL can't be built: \(remote)"
        }
    }

    /// Surface `description` so `localizedDescription` shows the real message rather than the
    /// generic "The operation couldn't be completed." system fallback.
    public var errorDescription: String? { description }
}

extension DependencyValues {
    public var worktreeClient: WorktreeClient {
        get { self[WorktreeClient.self] }
        set { self[WorktreeClient.self] = newValue }
    }
}

/// Carries git's own stderr so the message is clear (e.g. "fatal: a branch named '…' already exists").
public struct GitError: Error, LocalizedError, CustomStringConvertible {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(arguments.joined(separator: " ")) failed (status \(status)): \(detail)"
    }

    /// Surface `description` so `localizedDescription` shows git's real stderr rather than the
    /// generic "The operation couldn't be completed." system fallback.
    public var errorDescription: String? { description }
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

    /// The worktree's checked-out branch name.
    static func currentBranch(in worktree: URL) throws -> String {
        try capture(["-C", worktree.path, "rev-parse", "--abbrev-ref", "HEAD"])
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
