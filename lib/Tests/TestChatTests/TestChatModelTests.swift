import Agent
import Dependencies
import Foundation
import Testing
import Transcript
@testable import TestChat

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTestSession(storageRoot: URL) throws -> Session {
    let sessionId = Session.ID(rawValue: UUID())
    let dataDir = storageRoot.appendingPathComponent(sessionId.rawValue.uuidString)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    return Session(id: sessionId, worktree: URL(fileURLWithPath: "/tmp"), mode: .readOnly, dataDir: dataDir)
}

private func appendSuccessfulTurn(to session: Session, prompt: String, response: String) throws {
    let writer = try TranscriptWriter(url: session.transcript, append: true)
    let now = Date()
    try writer.write(.turnStarted(.init(userPrompt: prompt, attachedFiles: [], startedAt: now)))
    let result = Data("{\"type\":\"result\",\"result\":\"\(response)\",\"is_error\":false}".utf8)
    try writer.writeLine(result)
    try writer.write(.turnEnded(.init(endedAt: now, durationMs: 100)))
}

private func appendFailedTurn(to session: Session, prompt: String, errorMessage: String) throws {
    let writer = try TranscriptWriter(url: session.transcript, append: true)
    let now = Date()
    try writer.write(.turnStarted(.init(userPrompt: prompt, attachedFiles: [], startedAt: now)))
    try writer.write(.turnFailed(.init(endedAt: now, durationMs: 100, errorKind: "harnessFailed", errorMessage: errorMessage)))
}

// MARK: - Spy

private final class AgentSpy: @unchecked Sendable {
    var startCount = 0
    var sendCount = 0
}

// MARK: - Tests

@MainActor
@Suite("TestChatModel")
struct TestChatModelTests {

    // AC1: The first prompt starts a Session; subsequent prompts resume it via send.
    @Test func firstPromptCallsStart_followUpCallsSend() async throws {
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let spy = AgentSpy()

        let model = withDependencies {
            $0.agentClient.start = { request in
                spy.startCount += 1
                let session = try makeTestSession(storageRoot: request.storageRoot)
                FileManager.default.createFile(atPath: session.transcript.path, contents: nil)
                return session
            }
            $0.agentClient.send = { request in
                spy.sendCount += 1
                return request.session
            }
        } operation: {
            TestChatModel(worktree: URL(fileURLWithPath: "/tmp"))
        }

        model.draftText = "hello"
        model.submit()
        await model.runTask?.value
        #expect(spy.startCount == 1)
        #expect(spy.sendCount == 0)

        model.draftText = "follow up"
        model.submit()
        await model.runTask?.value
        #expect(spy.startCount == 1)
        #expect(spy.sendCount == 1)
    }

    // AC2: Each Turn's prompt and final answer append to the same conversation in order.
    @Test func turnsAppendToConversationInOrder() async throws {
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let model = withDependencies {
            $0.agentClient.start = { request in
                let session = try makeTestSession(storageRoot: request.storageRoot)
                let writer = try TranscriptWriter(url: session.transcript)
                let now = Date()
                try writer.write(.sessionStarted(.init(
                    sessionId: session.id, worktree: session.worktree,
                    mode: session.mode, attachedFiles: [], startedAt: now
                )))
                try appendSuccessfulTurn(to: session, prompt: request.prompt, response: "First response")
                return session
            }
            $0.agentClient.send = { request in
                try appendSuccessfulTurn(to: request.session, prompt: request.prompt, response: "Second response")
                return request.session
            }
        } operation: {
            TestChatModel(worktree: URL(fileURLWithPath: "/tmp"))
        }

        model.draftText = "first"
        model.submit()
        await model.runTask?.value

        model.draftText = "second"
        model.submit()
        await model.runTask?.value

        let messages = model.messages
        #expect(messages.count == 4)
        #expect(messages[0].role == .user && messages[0].text == "first")
        #expect(messages[1].role == .assistant && messages[1].text == "First response")
        #expect(messages[2].role == .user && messages[2].text == "second")
        #expect(messages[3].role == .assistant && messages[3].text == "Second response")
    }

    // AC3: A failed Turn renders inline as an error entry.
    @Test func failedTurnRendersAsErrorEntry() async throws {
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let model = withDependencies {
            $0.agentClient.start = { request in
                let session = try makeTestSession(storageRoot: request.storageRoot)
                let writer = try TranscriptWriter(url: session.transcript)
                let now = Date()
                try writer.write(.sessionStarted(.init(
                    sessionId: session.id, worktree: session.worktree,
                    mode: session.mode, attachedFiles: [], startedAt: now
                )))
                try appendSuccessfulTurn(to: session, prompt: request.prompt, response: "Hello!")
                return session
            }
            $0.agentClient.send = { request in
                try appendFailedTurn(to: request.session, prompt: request.prompt, errorMessage: "Harness crashed")
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Harness crashed"])
            }
        } operation: {
            TestChatModel(worktree: URL(fileURLWithPath: "/tmp"))
        }

        model.draftText = "start"
        model.submit()
        await model.runTask?.value

        model.draftText = "fail me"
        model.submit()
        await model.runTask?.value

        let messages = model.messages
        #expect(messages.count == 4)
        #expect(messages[2].role == .user && messages[2].text == "fail me")
        #expect(messages[3].role == .assistant && messages[3].isError == true)
    }

    // AC4: After a failure, the Session stays usable and further prompts can be sent.
    @Test func sessionStaysUsableAfterFailedSend() async throws {
        let storageRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let spy = AgentSpy()

        let model = withDependencies {
            $0.agentClient.start = { request in
                spy.startCount += 1
                let session = try makeTestSession(storageRoot: request.storageRoot)
                let writer = try TranscriptWriter(url: session.transcript)
                let now = Date()
                try writer.write(.sessionStarted(.init(
                    sessionId: session.id, worktree: session.worktree,
                    mode: session.mode, attachedFiles: [], startedAt: now
                )))
                try appendSuccessfulTurn(to: session, prompt: request.prompt, response: "OK")
                return session
            }
            $0.agentClient.send = { request in
                spy.sendCount += 1
                if spy.sendCount == 1 {
                    throw NSError(domain: "test", code: 1)
                }
                try appendSuccessfulTurn(to: request.session, prompt: request.prompt, response: "Recovered")
                return request.session
            }
        } operation: {
            TestChatModel(worktree: URL(fileURLWithPath: "/tmp"))
        }

        model.draftText = "hello"
        model.submit()
        await model.runTask?.value
        #expect(spy.startCount == 1)
        #expect(spy.sendCount == 0)

        model.draftText = "crash"
        model.submit()
        await model.runTask?.value
        #expect(spy.startCount == 1)
        #expect(spy.sendCount == 1)
        #expect(model.messages.last?.isError == true)

        model.draftText = "retry"
        model.submit()
        await model.runTask?.value
        #expect(spy.startCount == 1)
        #expect(spy.sendCount == 2)
    }
}
