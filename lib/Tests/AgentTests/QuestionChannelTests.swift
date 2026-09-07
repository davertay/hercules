import Foundation
import Testing

@testable import Agent

/// The `ask_user` channel, driven from both ends at once in one process. There is no subprocess here,
/// no Harness and no MCP: the child's half and the app's half are both `QuestionChannel`, so the
/// protocol they meet at is exercised directly rather than through a stand-in that can agree with the
/// wrong thing.
@Suite("QuestionChannel — the ask_user protocol")
struct QuestionChannelTests {
    private let storage = Question(
        header: "Storage",
        question: "How should offline notes be stored?",
        options: [
            Question.Option(label: "Use SQLite", description: "A real database, migrations and all"),
            Question.Option(label: "Use a flat file", description: "One JSON blob, rewritten on save"),
        ]
    )
    private let sync = Question(
        header: "Sync",
        question: "What should happen to edits made while offline?",
        multiSelect: true,
        options: [
            Question.Option(label: "Last write wins", description: "Simplest, loses concurrent edits"),
            Question.Option(label: "Keep both", description: "Fork the note and let the user merge"),
        ]
    )

    /// A channel on its own temp directory, polled fast enough that the tests aren't waiting on it.
    private func makeChannel() -> QuestionChannel {
        QuestionChannel(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuestionChannelTests-\(UUID().uuidString)", isDirectory: true),
            pollInterval: .milliseconds(2)
        )
    }

    /// Polls until `condition` holds. Both ends of the channel are file-driven, so a test that asserts
    /// on one end's effect has to wait for a write it didn't make itself.
    private func eventually(
        _ condition: () throws -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition never held", sourceLocation: sourceLocation)
    }

    // MARK: - Announce, then answer

    /// The whole round trip: the child announces and blocks, the app sees the call, the app answers,
    /// the child wakes with exactly that answer — two questions in the one call, and the selection and
    /// the note arriving as the separate fields they were sent as.
    @Test func anAnnouncedCallReceivesTheAnswerDeliveredToIt() async throws {
        let channel = makeChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let call = QuestionChannel.Call(callID: "toolu_01", questions: [storage, sync])

        let asking = Task { try await channel.ask(call) }
        #expect(try await channel.nextCalls() == [call])

        let answer = Answer.answered([
            QuestionAnswer(
                header: "Storage",
                selected: ["Use SQLite"],
                note: "but keep migrations in a separate file"
            ),
            QuestionAnswer(header: "Sync", selected: ["Last write wins", "Keep both"]),
        ])
        try channel.deliver(answer, to: call.callID)

        let received = try await asking.value
        #expect(received == answer)

        guard case .answered(let answers) = received else {
            Issue.record("Expected an answered reply, got \(received)")
            return
        }
        #expect(answers.first?.selected == ["Use SQLite"])
        #expect(answers.first?.note == "but keep migrations in a separate file")
        #expect(answers.last?.note == nil)
    }

    /// Cancellation is a shape of answer like any other and has to survive the trip as itself: the
    /// child turns it into the tool's `is_error` result, and an `.answered([])` in its place would read
    /// to the model as permission to guess.
    @Test func theCancelledAnswerRoundTripsIntact() async throws {
        let channel = makeChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let call = QuestionChannel.Call(callID: "toolu_01", questions: [storage])

        let asking = Task { try await channel.ask(call) }
        _ = try await channel.nextCalls()

        try channel.deliver(.cancelled, to: call.callID)

        #expect(try await asking.value == .cancelled)
    }

    // MARK: - Correlation

    /// The Harness abandons a tool call without telling the server, so an answer for a call nobody is
    /// waiting on is an ordinary event. It must go nowhere: the call that *is* waiting has to leave it
    /// alone and go on to receive its own.
    @Test func anAnswerForAnotherCallIsIgnoredRatherThanConsumed() async throws {
        let channel = makeChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let call = QuestionChannel.Call(callID: "toolu_01", questions: [storage])

        let asking = Task { try await channel.ask(call) }
        _ = try await channel.nextCalls()

        try channel.deliver(
            .answered([QuestionAnswer(header: "Storage", selected: ["Use a flat file"])]),
            to: "toolu_abandoned"
        )

        // Several poll ticks' worth: a channel that was going to take the stray answer has taken it by
        // now, and the call would no longer be pending.
        try await Task.sleep(for: .milliseconds(50))
        #expect(try channel.pendingCalls() == [call])

        let mine = Answer.answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])])
        try channel.deliver(mine, to: call.callID)

        #expect(try await asking.value == mine)
    }

    /// The same guard, one layer down: a delivery that reaches this call's file but names another call
    /// in its payload is ignored too. The file name is the weaker half of the correlation — a
    /// case-insensitive volume can land two call ids on one name — so it is the payload that decides.
    @Test func anAnswerBearingAnotherCallsIDIsIgnoredRatherThanConsumed() async throws {
        let channel = makeChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let call = QuestionChannel.Call(callID: "toolu_01", questions: [storage])

        let asking = Task { try await channel.ask(call) }
        _ = try await channel.nextCalls()

        // Written for one call, delivered to the other's file name.
        try channel.deliver(
            .answered([QuestionAnswer(header: "Storage", selected: ["Use a flat file"])]),
            to: "toolu_99"
        )
        try FileManager.default.moveItem(at: channel.answerFile("toolu_99"), to: channel.answerFile(call.callID))

        // Several poll ticks' worth: a channel that was going to read the forged delivery has read it
        // by now, and would answer with it below instead of with the real one.
        try await Task.sleep(for: .milliseconds(50))

        let mine = Answer.answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])])
        try channel.deliver(mine, to: call.callID)

        #expect(try await asking.value == mine)
    }

    // MARK: - The wedge

    /// A second call announcing while the first is still pending must be served, not swallowed. This is
    /// the wedge the spike surfaced: the Harness abandons a call silently and the model retries, so a
    /// channel that could hold only one pending call would leave the retry waiting forever — and would
    /// fail without saying so.
    @Test func aSecondCallAnnouncingWhileOneIsPendingIsServed() async throws {
        let channel = makeChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let first = QuestionChannel.Call(callID: "toolu_first", questions: [storage])
        let second = QuestionChannel.Call(callID: "toolu_second", questions: [sync])

        let askingFirst = Task { try await channel.ask(first) }
        #expect(try await channel.nextCalls() == [first])

        let askingSecond = Task { try await channel.ask(second) }
        try await eventually { try channel.pendingCalls().count == 2 }
        #expect(try channel.pendingCalls() == [first, second])

        // The second resolves on its own while the first stays exactly where it was.
        let secondAnswer = Answer.answered([QuestionAnswer(header: "Sync", selected: ["Keep both"])])
        try channel.deliver(secondAnswer, to: second.callID)
        #expect(try await askingSecond.value == secondAnswer)
        try await eventually { try channel.pendingCalls() == [first] }

        let firstAnswer = Answer.answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])])
        try channel.deliver(firstAnswer, to: first.callID)
        #expect(try await askingFirst.value == firstAnswer)
    }

    // MARK: - Where the state lives

    /// The channel's state is the Turn's scratch and nothing else: it is written under the Turn's own
    /// directory, and the existing per-Turn cleanup takes it away. Nothing here touches the Store.
    @Test func theChannelsStateLivesInTheTurnsScratchAndLeavesWithIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestionChannelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = Harness.TurnScratch(directory: root, turnID: UUID())

        let channel = QuestionChannel(directory: scratch.questionChannelDirectory, pollInterval: .milliseconds(2))
        #expect(channel.directory.path.hasPrefix(root.path))

        let call = QuestionChannel.Call(callID: "toolu_01", questions: [storage])
        let asking = Task { try await channel.ask(call) }
        _ = try await channel.nextCalls()
        #expect(FileManager.default.fileExists(atPath: channel.announceFile(call.callID).path))

        try channel.deliver(.cancelled, to: call.callID)
        _ = try await asking.value
        #expect(FileManager.default.fileExists(atPath: channel.directory.path))

        scratch.removeTurnFiles()
        #expect(!FileManager.default.fileExists(atPath: channel.directory.path))
    }
}
