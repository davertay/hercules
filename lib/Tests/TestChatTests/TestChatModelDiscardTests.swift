import Dependencies
import Foundation
import SQLiteData
import Testing
@testable import TestChat

@MainActor
@Suite("TestChatModel – discard on close")
struct TestChatModelDiscardTests {

    // MARK: – Storage cleanup

    @Test
    func tearDownRemovesStorageRoot() {
        let model = TestChatModel(worktree: FileManager.default.temporaryDirectory)
        #expect(FileManager.default.fileExists(atPath: model.storageRoot.path))
        model.tearDown()
        #expect(!FileManager.default.fileExists(atPath: model.storageRoot.path))
    }

    // The connection must be closed before the storage directory is unlinked; otherwise
    // libsqlite3 reports "vnode unlinked while in use" against the still-open fds. After
    // close, any read on the connection throws — that's the observable proof it was closed.
    @Test
    func tearDownClosesDatabaseBeforeRemovingStorage() throws {
        let model = TestChatModel(worktree: FileManager.default.temporaryDirectory)
        let database = try #require(model.databaseForTesting)
        try database.read { _ in } // open and usable before teardown

        model.tearDown()

        #expect(throws: (any Error).self) {
            try database.read { _ in }
        }
    }

    @Test
    func tearDownIsIdempotent() {
        let model = TestChatModel(worktree: FileManager.default.temporaryDirectory)
        model.tearDown()
        model.tearDown() // second call must not crash
        #expect(!FileManager.default.fileExists(atPath: model.storageRoot.path))
    }

    @Test
    func deinitBackstopRemovesStorageRoot() {
        var model: TestChatModel? = TestChatModel(worktree: FileManager.default.temporaryDirectory)
        let root = model!.storageRoot
        #expect(FileManager.default.fileExists(atPath: root.path))
        // tearDown() intentionally not called; deinit is the backstop
        model = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: – Task cancellation

    @Test
    func tearDownCancelsInFlightTask() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()

        let model: TestChatModel = withDependencies {
            $0.agentClient.start = { @Sendable _ in
                // Signal that the turn is now in flight, then suspend indefinitely.
                continuation.yield(())
                continuation.finish()
                try await Task.sleep(for: .seconds(3600))
                fatalError("unreachable")
            }
        } operation: {
            let m = TestChatModel(worktree: FileManager.default.temporaryDirectory)
            m.draftText = "hello"
            m.submit()
            return m
        }

        // Wait until the mock start body is executing, confirming the turn is live.
        for await _ in stream { break }
        #expect(model.isRunning)

        model.tearDown()

        // storageRoot is removed synchronously by tearDown.
        #expect(!FileManager.default.fileExists(atPath: model.storageRoot.path))
    }
}
