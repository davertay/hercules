import Foundation
import MCP
import Store
import Testing

@testable import Agent
@testable import IssueMCP

@Suite("AskUser")
struct AskUserTests {

    // MARK: - The tool

    /// The one thing the model has to be told verbatim, since MCP tools are deferred rather than listed
    /// and are reached by their exact qualified name. It qualifies through the descriptor's own server
    /// name, so the string the house rules name and the string the server answers to cannot drift apart.
    @Test func servesOneToolQualifiedAsAskUser() {
        let descriptor = MCPServer.questionAsker(
            command: "/path/to/Hercules",
            channelDirectory: URL(fileURLWithPath: "/tmp/session/turn.questions", isDirectory: true)
        )

        #expect(descriptor.tools == [askUserTool.name])
        #expect(descriptor.qualifiedToolNames == ["mcp__hercules_ask__ask_user"])
    }

    /// The descriptor's name is deliberately not the writers', so a Turn can carry the question tool and
    /// a writer at once — a per-Turn override replaces the pinned set rather than merging into it, and
    /// the config is keyed by server name, so one shared name would drop one of the two.
    @Test func theAskServerIsNamedApartFromTheWriters() {
        let asker = MCPServer.questionAsker(
            command: "/path/to/Hercules",
            channelDirectory: URL(fileURLWithPath: "/tmp/turn.questions", isDirectory: true)
        )
        let writer = MCPServer.artifactWriter(
            command: "/path/to/Hercules",
            artifactURL: URL(fileURLWithPath: "/tmp/wf/phases/design/summary.md")
        )

        #expect(asker.name != writer.name)
        #expect(asker.args == ["--mcp-ask-server", "--question-channel", "/tmp/turn.questions"])
    }

    // MARK: - Argument decoding

    @Test func decodesArgumentsFromMCPValues() throws {
        let arguments = try AskUserArguments(mcpArguments: [
            "questions": .array([
                .object([
                    "header": .string("Storage"),
                    "question": .string("How should offline notes be stored?"),
                    "multiSelect": .bool(false),
                    "options": .array([
                        .object([
                            "label": .string("Use SQLite"),
                            "description": .string("A real database, migrations and all"),
                        ]),
                        .object([
                            "label": .string("Use a flat file"),
                            "description": .string("One JSON blob, rewritten on save"),
                        ]),
                    ]),
                ])
            ])
        ])

        #expect(
            arguments == AskUserArguments(questions: [
                Question(
                    header: "Storage",
                    question: "How should offline notes be stored?",
                    options: [
                        Question.Option(label: "Use SQLite", description: "A real database, migrations and all"),
                        Question.Option(label: "Use a flat file", description: "One JSON blob, rewritten on save"),
                    ]
                )
            ])
        )
    }

    /// A model that leaves out the boolean, or that asks an open question with nothing on offer, is
    /// still asking a question. Neither is worth refusing the call over.
    @Test func decodesAQuestionWithoutMultiSelectOrOptions() throws {
        let arguments = try AskUserArguments(mcpArguments: [
            "questions": .array([
                .object([
                    "header": .string("Naming"),
                    "question": .string("What should the module be called?"),
                ])
            ])
        ])

        #expect(arguments.questions == [Question(header: "Naming", question: "What should the module be called?")])
    }

    @Test func malformedArgumentsThrow() {
        // Missing the required `questions` field.
        #expect(throws: (any Error).self) {
            try AskUserArguments(mcpArguments: [:])
        }
        // Wrong type for `questions`.
        #expect(throws: (any Error).self) {
            try AskUserArguments(mcpArguments: ["questions": .string("ask me something")])
        }
        // A question missing the fields that carry its meaning.
        #expect(throws: (any Error).self) {
            try AskUserArguments(mcpArguments: ["questions": .array([.object(["header": .string("Storage")])])])
        }
        // No arguments at all.
        #expect(throws: (any Error).self) {
            try AskUserArguments(mcpArguments: nil)
        }
    }

    /// A malformed call comes back as a tool error the model can read and retry from, rather than as a
    /// failed request that would take the connection down with it.
    @Test func aMalformedCallIsAToolErrorRatherThanAFailure() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await askUserCall(
            CallTool.Parameters(name: "ask_user", arguments: ["questions": .string("nope")]),
            asker: QuestionAsker(channelDirectory: directory)
        )

        #expect(result.isError == true)
        #expect(try Self.text(of: result).hasPrefix("ask_user failed:"))
        // Nothing was announced, so nobody is waiting on an answer to a call that never asked anything.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - The result payload

    /// The shape the house rules promise the model, spelled out once: an entry per question, keyed by
    /// the `header` it authored, the picked labels verbatim, and the note it typed alongside them.
    @Test func serialisesTheAnswersPayload() throws {
        let text = try askUserPayloadText([
            QuestionAnswer(
                header: "Storage",
                selected: ["Use SQLite"],
                note: "but keep migrations in a separate file"
            )
        ])

        #expect(
            text == """
                {"answers":[{"header":"Storage",\
                "note":"but keep migrations in a separate file",\
                "selected":["Use SQLite"]}]}
                """
        )
    }

    /// A pure free-text answer — nothing picked, everything typed. The empty selection is the signal
    /// that there is no option to match against, so it is sent rather than omitted.
    @Test func aFreeTextAnswerHasAnEmptySelection() throws {
        let text = try askUserPayloadText([
            QuestionAnswer(header: "Storage", selected: [], note: "Postgres, actually")
        ])

        #expect(text == #"{"answers":[{"header":"Storage","note":"Postgres, actually","selected":[]}]}"#)
    }

    /// A pick with nothing typed alongside it carries no `note` at all, rather than an empty one that
    /// would read as a qualification the user never made.
    @Test func theNoteIsOmittedWhenEmpty() throws {
        #expect(
            try askUserPayloadText([QuestionAnswer(header: "Sync", selected: ["Keep both"])])
                == #"{"answers":[{"header":"Sync","selected":["Keep both"]}]}"#
        )
        #expect(
            try askUserPayloadText([QuestionAnswer(header: "Sync", selected: ["Keep both"], note: "")])
                == #"{"answers":[{"header":"Sync","selected":["Keep both"]}]}"#
        )
    }

    @Test func multiSelectAndSeveralQuestionsSerialiseTogether() throws {
        let text = try askUserPayloadText([
            QuestionAnswer(header: "Storage", selected: ["Use SQLite"]),
            QuestionAnswer(header: "Sync", selected: ["Last write wins", "Keep both"], note: "start simple"),
        ])

        #expect(
            text == """
                {"answers":[{"header":"Storage","selected":["Use SQLite"]},\
                {"header":"Sync","note":"start simple","selected":["Last write wins","Keep both"]}]}
                """
        )
    }

    // MARK: - Cancellation

    /// Dismissing the question is reported as an error, not as a success carrying no answer: a
    /// well-behaved model reads "no answer, but fine" as permission to guess, which is the failure this
    /// tool exists to remove. The text says so in as many words.
    @Test func cancellationIsErrorFlaggedAndTellsTheAgentToStop() throws {
        let result = try askUserResult(for: .cancelled)

        #expect(result.isError == true)
        let text = try Self.text(of: result)
        #expect(text.contains("cancelled"))
        #expect(text.contains("Do not assume an answer"))
        #expect(text.contains("stop and wait for the next instruction"))
    }

    @Test func anAnsweredCallIsNotErrorFlagged() throws {
        let result = try askUserResult(
            for: .answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])])
        )

        #expect(result.isError == nil)
        #expect(try Self.text(of: result) == #"{"answers":[{"header":"Storage","selected":["Use SQLite"]}]}"#)
    }

    // MARK: - Correlation

    /// The call is correlated by the Harness's own `tool_use.id`, which arrives in the `tools/call`
    /// params' `_meta` and matches the id in the streamed transcript exactly.
    @Test func theCallIsKeyedByTheHarnessesToolUseID() {
        let meta = Metadata(additionalFields: [
            "claudecode/toolUseId": .string("toolu_01ABC"),
            "progressToken": .int(3),
        ])

        #expect(askUserCallID(meta) == "toolu_01ABC")
    }

    /// Correlation only needs the two sides to agree on some string, so a caller that sends no `_meta`
    /// is still served — it forfeits the tie-back to the transcript row and nothing else.
    @Test func aCallWithoutAToolUseIDStillGetsAnID() {
        #expect(!askUserCallID(nil).isEmpty)
        #expect(askUserCallID(nil) != askUserCallID(nil))
    }

    // MARK: - The round trip

    /// The handler driven end to end against the channel, with the user's answer supplied as a value:
    /// the call announces itself, the app answers it, and the tool result is the payload the model was
    /// promised.
    @Test func aCallBlocksUntilAnsweredAndReturnsThePayload() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = QuestionChannel(directory: directory)

        let calling = Task {
            await askUserCall(
                Self.parameters(callID: "toolu_01", header: "Storage", question: "SQLite or a file?"),
                asker: QuestionAsker(channelDirectory: directory)
            )
        }

        let pending = try await channel.nextCalls()
        #expect(pending.map(\.callID) == ["toolu_01"])
        #expect(pending.first?.questions.first?.header == "Storage")

        try channel.deliver(
            .answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"], note: "with migrations")]),
            to: "toolu_01"
        )

        let result = await calling.value
        #expect(result.isError == nil)
        #expect(
            try Self.text(of: result) == """
                {"answers":[{"header":"Storage","note":"with migrations","selected":["Use SQLite"]}]}
                """
        )
    }

    @Test func aDismissedCallReturnsTheCancellationResult() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = QuestionChannel(directory: directory)

        let calling = Task {
            await askUserCall(
                Self.parameters(callID: "toolu_01", header: "Storage", question: "SQLite or a file?"),
                asker: QuestionAsker(channelDirectory: directory)
            )
        }
        _ = try await channel.nextCalls()

        try channel.deliver(.cancelled, to: "toolu_01")

        let result = await calling.value
        #expect(result.isError == true)
        #expect(try Self.text(of: result) == askUserCancelledText)
    }

    // MARK: - The wedge

    /// A second call arriving while the first is still waiting must be served, not swallowed. This is
    /// the sharpest hazard in the whole design and a silent one: the Harness abandons a call without
    /// telling the server, the model retries, and a handler that served one call at a time would leave
    /// the retry queued behind a call nobody is coming back for.
    ///
    /// Answering the second first is the point — it resolves on its own while the first stays exactly
    /// where it was.
    @Test func aSecondCallArrivingWhileOneIsPendingIsServed() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = QuestionChannel(directory: directory)
        let asker = QuestionAsker(channelDirectory: directory)

        let first = Task {
            await askUserCall(
                Self.parameters(callID: "toolu_first", header: "Storage", question: "SQLite or a file?"),
                asker: asker
            )
        }
        _ = try await channel.nextCalls()

        let second = Task {
            await askUserCall(
                Self.parameters(callID: "toolu_second", header: "Sync", question: "What wins on conflict?"),
                asker: asker
            )
        }
        try await Self.eventually { try channel.pendingCalls().count == 2 }

        try channel.deliver(.answered([QuestionAnswer(header: "Sync", selected: ["Keep both"])]), to: "toolu_second")
        #expect(try Self.text(of: await second.value) == #"{"answers":[{"header":"Sync","selected":["Keep both"]}]}"#)
        try await Self.eventually { try channel.pendingCalls().map(\.callID) == ["toolu_first"] }

        try channel.deliver(.answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])]), to: "toolu_first")
        #expect(
            try Self.text(of: await first.value) == #"{"answers":[{"header":"Storage","selected":["Use SQLite"]}]}"#
        )
    }

    /// The same wedge one layer out, through a real `Server` over a paired in-memory transport — no
    /// subprocess, no stdio, but the SDK's own receive loop. The handler being concurrent is only half
    /// the guarantee; the other half is that the connection goes on being *read* while a call is
    /// blocked, so the second `tools/call` reaches a handler at all.
    @Test func aSecondToolCallIsReadWhileTheFirstIsBlocked() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = QuestionChannel(directory: directory)

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeAskUserMCPServer(channelDirectory: directory)
        try await server.start(transport: serverTransport)
        let client = Client(name: "AskUserTests", version: "1.0.0")
        try await client.connect(transport: clientTransport)
        defer {
            Task {
                await client.disconnect()
                await server.stop()
            }
        }

        #expect(try await client.listTools().tools.map(\.name) == ["ask_user"])

        let first = Task { () async throws -> (content: [Tool.Content], isError: Bool?) in
            try await client.callTool(
                name: "ask_user",
                arguments: Self.questionsArgument(header: "Storage", question: "SQLite or a file?"),
                meta: Metadata(additionalFields: ["claudecode/toolUseId": .string("toolu_first")])
            )
        }
        _ = try await channel.nextCalls()

        // Written to a connection whose reader is inside the first call. It has to be picked up anyway.
        let second = Task { () async throws -> (content: [Tool.Content], isError: Bool?) in
            try await client.callTool(
                name: "ask_user",
                arguments: Self.questionsArgument(header: "Sync", question: "What wins on conflict?"),
                meta: Metadata(additionalFields: ["claudecode/toolUseId": .string("toolu_second")])
            )
        }
        try await Self.eventually { try channel.pendingCalls().count == 2 }

        try channel.deliver(.answered([QuestionAnswer(header: "Sync", selected: ["Keep both"])]), to: "toolu_second")
        let secondResult = try await second.value
        #expect(secondResult.isError == nil)

        try channel.deliver(.answered([QuestionAnswer(header: "Storage", selected: ["Use SQLite"])]), to: "toolu_first")
        let firstResult = try await first.value
        #expect(firstResult.isError == nil)
    }

    // MARK: - Launch argument parsing

    @Test func parsesSubcommandArguments() {
        let config = AskUserMCPLaunch.parse([
            "/path/to/Hercules", "--mcp-ask-server",
            "--question-channel", "/tmp/wf/sessions/S/TURN.questions",
        ])
        #expect(config == AskUserMCPLaunch.Configuration(channelPath: "/tmp/wf/sessions/S/TURN.questions"))
    }

    /// An ordinary GUI launch must fall through untouched — the branch is what keeps the re-exec off the
    /// AppKit path, and it must not claim a launch that isn't the server's.
    @Test func returnsNilWithoutSubcommand() {
        #expect(AskUserMCPLaunch.parse(["/path/to/Hercules"]) == nil)
        // The channel operand alone, without the subcommand, is not the ask server.
        #expect(AskUserMCPLaunch.parse(["/path/to/Hercules", "--question-channel", "/tmp/q"]) == nil)
        // Nor is another server's subcommand.
        #expect(AskUserMCPLaunch.parse(["/path/to/Hercules", "--mcp-artifact-server", "--artifact-path", "/x"]) == nil)
    }

    @Test func returnsNilWhenChannelOperandMissing() {
        #expect(AskUserMCPLaunch.parse(["--mcp-ask-server"]) == nil)
        // Flag present but no following value.
        #expect(AskUserMCPLaunch.parse(["--mcp-ask-server", "--question-channel"]) == nil)
    }

    // MARK: - Helpers

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AskUserTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// One well-formed `tools/call` for a single question, carrying the tool_use id in `_meta` the way
    /// the Harness sends it.
    private static func parameters(callID: String, header: String, question: String) -> CallTool.Parameters {
        CallTool.Parameters(
            name: "ask_user",
            arguments: questionsArgument(header: header, question: question),
            meta: Metadata(additionalFields: ["claudecode/toolUseId": .string(callID)])
        )
    }

    /// The raw `questions` argument for one two-option question, as the model would send it.
    private static func questionsArgument(header: String, question: String) -> [String: Value] {
        [
            "questions": .array([
                .object([
                    "header": .string(header),
                    "question": .string(question),
                    "multiSelect": .bool(false),
                    "options": .array([
                        .object(["label": .string("Yes"), "description": .string("Go ahead")]),
                        .object(["label": .string("No"), "description": .string("Don't")]),
                    ]),
                ])
            ])
        ]
    }

    private static func text(of result: CallTool.Result) throws -> String {
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            throw AskUserTestFailure.notText
        }
        return text
    }

    /// Polls until `condition` holds. The channel is file-driven, so a test asserting on the effect of a
    /// write it didn't make has to wait for it.
    private static func eventually(
        _ condition: () throws -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition never held", sourceLocation: sourceLocation)
    }
}

private enum AskUserTestFailure: Error {
    case notText
}
