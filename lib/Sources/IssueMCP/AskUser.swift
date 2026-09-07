import Agent
import Foundation
import MCP
import Store

// The seam below the MCP transport, driven directly by tests without real stdio: raw tool arguments in
// one side, the tool's result out the other, with the user's answer supplied as a value.

/// The `ask_user` tool's arguments: the questions to put to the user.
///
/// The schema mirrors the Harness's own retired `AskUserQuestion` tool field for field, so the model
/// reaches for this tool with the prior it already has and no prompt spent teaching it one.
public struct AskUserArguments: Codable, Equatable, Sendable {
    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    private enum CodingKeys: String, CodingKey {
        case questions
    }

    /// Throws when the required field is missing or the wrong type — reported back as a tool error.
    public init(mcpArguments: [String: Value]?) throws {
        let data = try JSONEncoder().encode(Value.object(mcpArguments ?? [:]))
        self = try JSONDecoder().decode(AskUserArguments.self, from: data)
    }
}

/// The Harness's own `tool_use.id` for this call, as it arrives in the `tools/call` params' `_meta`. It
/// matches the `tool_use.id` in the streamed transcript exactly, which is what lets the app tie the
/// question it renders back to the row the call produced.
let toolUseIDMetaKey = "claudecode/toolUseId"

/// The id this call is correlated by. Correlation only needs the two sides to agree on a string, so a
/// caller that sends no `_meta` still gets served — it forfeits the tie-back to the transcript, nothing
/// more.
func askUserCallID(_ meta: Metadata?) -> String {
    meta?[toolUseIDMetaKey]?.stringValue ?? UUID().uuidString
}

/// What the model is told when the user dismisses the question.
///
/// Delivered `is_error`, not as a polite success: "the user did not answer" reported as success hands a
/// well-behaved model permission to guess, which is the failure this whole tool exists to remove,
/// reintroduced at the cancel path.
let askUserCancelledText = """
    ask_user cancelled: the user dismissed the question without answering. Do not assume an answer; \
    stop and wait for the next instruction.
    """

/// The tool's result payload. Structured rather than prose because several questions, each with a
/// multi-select and a note, is genuinely structured data — and because it is then symmetric with the
/// structured input the model supplied.
struct AskUserPayload: Codable, Equatable {
    var answers: [QuestionAnswer]
}

/// The user's answers as the tool's result text: `{"answers":[…]}`, one entry per question, keyed by the
/// `header` the model itself authored.
///
/// `selected` carries the option labels back verbatim — the model wrote them moments earlier, so it
/// matches them exactly rather than by eye — and stays an empty list when the user answered in free text
/// alone. `note` is dropped when there is nothing in it, so an answer without one doesn't read as one
/// with an empty answer.
func askUserPayloadText(_ answers: [QuestionAnswer]) throws -> String {
    let payload = AskUserPayload(
        answers: answers.map {
            QuestionAnswer(
                header: $0.header,
                selected: $0.selected,
                note: ($0.note?.isEmpty ?? true) ? nil : $0.note
            )
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(payload), as: UTF8.self)
}

/// The tool result for an answer that has come back from the user.
func askUserResult(for answer: Answer) throws -> CallTool.Result {
    switch answer {
    case .answered(let answers):
        return CallTool.Result(
            content: [.text(text: try askUserPayloadText(answers), annotations: nil, _meta: nil)]
        )
    case .cancelled:
        return CallTool.Result(
            content: [.text(text: askUserCancelledText, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

/// Serves one `tools/call`: decode, put the questions to the user, and turn what comes back into the
/// tool's result. A malformed call is reported as a tool error rather than as a failed request, which
/// would tear the connection down.
///
/// Nothing here is shared between calls and nothing here is serialised against another call, so a second
/// call arriving while this one is still waiting is served alongside it rather than behind it. That is
/// the wedge the spike caught: the Harness abandons a call without telling the server, the model retries,
/// and a server that could only serve one at a time would leave the retry waiting on a call nobody is
/// coming back for — silently.
func askUserCall(_ params: CallTool.Parameters, asker: QuestionAsker) async -> CallTool.Result {
    do {
        let arguments = try AskUserArguments(mcpArguments: params.arguments)
        let answer = try await asker.ask(
            callID: askUserCallID(params._meta), questions: arguments.questions
        )
        return try askUserResult(for: answer)
    } catch {
        return CallTool.Result(
            content: [
                .text(text: "\(HerculesMCP.askUserToolName) failed: \(error)", annotations: nil, _meta: nil)
            ],
            isError: true
        )
    }
}
