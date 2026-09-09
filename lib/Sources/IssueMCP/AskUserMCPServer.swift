import Agent
import Foundation
import MCP
import Store

// The stdio MCP server serving the blocking `ask_user` tool (ADR 0006): the app binary re-executed with
// `--mcp-ask-server --question-channel <abs dir>`. The channel directory is a launch argument fixed by
// the app and invisible to the model, so a call can only reach the Turn that spawned the server.
//
// Unlike the writers, this server is named `hercules_ask` rather than `hercules`, so that a Turn can
// carry it alongside one of them — see `HerculesMCP.askServerName`. The fully-qualified tool name is
// therefore `mcp__hercules_ask__ask_user`, and it is that exact string the model must be told, because
// MCP tools are deferred rather than listed and are reached by name.

let askUserTool = Tool(
    name: HerculesMCP.askUserToolName,
    description: """
        Ask the user a question and wait for their answer. Use this whenever you need a decision, a \
        preference, or a fact only they have; it is the only way to reach them without ending your \
        turn. Offer the answers you would otherwise have spelled out in prose as options — the user \
        picks one (or several, with multiSelect), and may add a note that qualifies or replaces what \
        they picked. The call blocks until they answer, and returns \
        {"answers":[{"header":…,"selected":[…],"note":…}]}, keyed by the headers you supplied.
        """,
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "questions": .object([
                "type": .string("array"),
                "description": .string("The questions to put to the user."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "header": .object([
                            "type": .string("string"),
                            "description": .string(
                                "A short title for the question. The answer comes back under it, so make it distinct."
                            ),
                        ]),
                        "question": .object([
                            "type": .string("string"),
                            "description": .string("The question itself, as the user reads it."),
                        ]),
                        "multiSelect": .object([
                            "type": .string("boolean"),
                            "description": .string("Whether the user may pick more than one option."),
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "description": .string(
                                "The answers on offer. The user may also answer in their own words instead."
                            ),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "label": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "The option as a short phrase. It comes back verbatim, so it is the option's identity."
                                        ),
                                    ]),
                                    "description": .object([
                                        "type": .string("string"),
                                        "description": .string("What picking this option would mean."),
                                    ]),
                                ]),
                                "required": .array([.string("label"), .string("description")]),
                            ]),
                        ]),
                    ]),
                    "required": .array([
                        .string("header"), .string("question"), .string("multiSelect"), .string("options"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([.string("questions")]),
    ])
)

/// Serves the single `ask_user` tool over the host-fixed question channel. A malformed call returns a
/// tool error rather than tearing down the connection.
///
/// A call blocks for as long as the user takes to answer, and the server goes on serving the connection
/// meanwhile: the handler is an ordinary `async` closure the SDK dispatches off its receive loop, so a
/// second call is read and answered while the first is still waiting.
public func makeAskUserMCPServer(channelDirectory: URL) async -> Server {
    let asker = QuestionAsker(channelDirectory: channelDirectory)
    let server = Server(
        name: HerculesMCP.askServerName,
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [askUserTool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == askUserTool.name else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool \(params.name).", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        return await askUserCall(params, asker: asker)
    }

    return server
}

/// The `@main` re-exec branch, kept off the GUI path so the CLI invocation never initialises AppKit.
/// The flags parsed here are the `HerculesMCP` contract the descriptors in `Store` are built from.
public enum AskUserMCPLaunch {
    public struct Configuration: Equatable, Sendable {
        /// Absolute path of the Turn's question channel directory.
        public var channelPath: String

        public init(channelPath: String) {
            self.channelPath = channelPath
        }
    }

    /// Returns `nil` when the subcommand is absent (the GUI path) or its operand is missing.
    public static func parse(_ arguments: [String]) -> Configuration? {
        guard arguments.contains(HerculesMCP.askServerSubcommand) else { return nil }
        guard let channelPath = mcpLaunchValue(of: HerculesMCP.questionChannelFlag, in: arguments)
        else { return nil }
        return Configuration(channelPath: channelPath)
    }

    /// Runs the stdio server until the client closes the connection.
    public static func run(_ configuration: Configuration) async throws {
        let server = await makeAskUserMCPServer(
            channelDirectory: URL(fileURLWithPath: configuration.channelPath, isDirectory: true)
        )
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
