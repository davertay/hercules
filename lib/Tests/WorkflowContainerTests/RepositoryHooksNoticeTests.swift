import Dependencies
import Foundation
import SQLiteData
import Store
import Testing

@testable import WorkflowContainer

/// The disclosure that an untrusting Workflow is dropping hooks its repository declares. It fires on the
/// actual file, never the hypothetical one: a Workflow whose repo has no hooks says nothing, which is what
/// keeps the notice rare enough to be worth reading.
@Suite("Repository hooks notice")
struct RepositoryHooksNoticeTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func settingsDeclaringHooksAreDetected() throws {
        let worktree = try Self.makeWorktree(settings: #"{"hooks": {"Stop": []}}"#)
        defer { Self.remove(worktree) }

        #expect(repositorySettingsDeclareHooks(worktree: worktree))
    }

    /// Plenty of repos ship settings with no hooks in them at all; those lose nothing worth mentioning.
    @Test func settingsWithoutAHooksKeyAreNotDetected() throws {
        let worktree = try Self.makeWorktree(settings: #"{"model": "opus", "permissions": {"allow": []}}"#)
        defer { Self.remove(worktree) }

        #expect(!repositorySettingsDeclareHooks(worktree: worktree))
    }

    @Test func anAbsentSettingsFileIsNotDetected() throws {
        let worktree = try Self.makeWorktree(settings: nil)
        defer { Self.remove(worktree) }

        #expect(!repositorySettingsDeclareHooks(worktree: worktree))
    }

    /// Nothing here may throw: this runs on the path that opens a Workflow window.
    @Test(
        "Unparseable settings read as no hooks",
        arguments: [
            "{ this is not json",
            #"{"hooks": {"Stop": []}"#,  // truncated — a real half-written file
            "",
            "[]",
            #""hooks""#,
            "null",
        ]
    )
    func malformedSettingsAreNotDetected(contents: String) throws {
        let worktree = try Self.makeWorktree(settings: contents)
        defer { Self.remove(worktree) }

        #expect(!repositorySettingsDeclareHooks(worktree: worktree))
    }

    /// A `.claude/settings.json` that is a directory, not a file — unreadable rather than malformed.
    @Test func unreadableSettingsAreNotDetected() throws {
        let worktree = try Self.makeWorktree(settings: nil)
        defer { Self.remove(worktree) }
        try FileManager.default.createDirectory(
            at: worktree.appending(path: ".claude/settings.json"), withIntermediateDirectories: true
        )

        #expect(!repositorySettingsDeclareHooks(worktree: worktree))
    }

    /// The notice's two conditions together: hooks declared *and* trust withheld. Granting trust from the
    /// settings sheet clears it without reopening the Workflow, and revoking brings it back.
    @Test
    @MainActor
    func theNoticeTracksTheTrustToggle() async throws {
        let root = Self.makeTempDir()
        defer { Self.remove(root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try Self.writeSettings(#"{"hooks": {"PreToolUse": []}}"#, in: workflowWorktree(in: directory))

        let model = Self.makeModel(id: id, directory: directory)
        let database = try #require(model.database)
        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: Self.fixedDate, updatedAt: Self.fixedDate)
            }
            .execute(db)
        }
        try await model.$workflowRow.load()

        #expect(model.repositoryDeclaresHooks)
        #expect(model.isSuppressingRepositoryHooks)

        withDependencies { $0.date.now = Self.fixedDate } operation: {
            model.updateTrustsRepositorySettings(true)
        }
        try await model.$workflowRow.load()
        #expect(!model.isSuppressingRepositoryHooks)

        withDependencies { $0.date.now = Self.fixedDate } operation: {
            model.updateTrustsRepositorySettings(false)
        }
        try await model.$workflowRow.load()
        #expect(model.isSuppressingRepositoryHooks)
    }

    /// The other half: an untrusting Workflow whose repository declares nothing stays quiet.
    @Test
    @MainActor
    func aRepositoryWithoutHooksSaysNothing() async throws {
        let root = Self.makeTempDir()
        defer { Self.remove(root) }

        let id = UUID(0)
        let directory = root.appending(component: id.uuidString)
        try FileManager.default.createDirectory(
            at: workflowWorktree(in: directory), withIntermediateDirectories: true
        )

        let model = Self.makeModel(id: id, directory: directory)
        let database = try #require(model.database)
        try await database.write { db in
            try WorkflowRow.insert {
                WorkflowRow(id: id, repoPath: "/repo", createdAt: Self.fixedDate, updatedAt: Self.fixedDate)
            }
            .execute(db)
        }
        try await model.$workflowRow.load()

        #expect(!model.trustsRepositorySettings)
        #expect(!model.repositoryDeclaresHooks)
        #expect(!model.isSuppressingRepositoryHooks)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeModel(id: UUID, directory: URL) -> WorkflowContainerModel {
        withDependencies {
            $0.context = .live
            $0.uuid = .incrementing
            $0.date.now = fixedDate
        } operation: {
            WorkflowContainerModel(
                data: WorkflowWindowData(id: id, directory: directory, repoPath: "/repo")
            )
        }
    }

    /// A worktree directory, with `.claude/settings.json` written verbatim when `settings` is non-nil.
    private static func makeWorktree(settings: String?) throws -> URL {
        let worktree = makeTempDir()
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        if let settings {
            try writeSettings(settings, in: worktree)
        }
        return worktree
    }

    private static func writeSettings(_ contents: String, in worktree: URL) throws {
        let claude = worktree.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try contents.write(to: claude.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryHooksNoticeTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
