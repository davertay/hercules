import Foundation
import Testing

@testable import Agent

@Suite("StopFailureHook — unit")
struct StopFailureHookTests {
    private let dropFile = URL(fileURLWithPath: "/tmp/hercules-sessions/S/T.stop-failure.json")

    /// A temp file holding `contents`, deleted by the caller's `defer`.
    private func makeDropFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StopFailureHookTests-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Registration

    /// The whole registration, spelled out: one `StopFailure` entry, a wildcard matcher, and a
    /// shell-form command that redirects the payload it is handed on stdin into this Turn's drop-file.
    @Test func settingsRegisterAWildcardCommandHookWritingTheDropFile() throws {
        let json = String(decoding: try StopFailureHook.settingsJSON(dropFile: dropFile), as: UTF8.self)

        #expect(json == """
            {"hooks":{"StopFailure":[{"hooks":[{"command":"cat > \
            '/tmp/hercules-sessions/S/T.stop-failure.json'","type":"command"}],"matcher":"*"}]}}
            """)
    }

    /// The matcher captures whatever reason the Harness reports, including ones that don't exist yet —
    /// the point of not enumerating today's taxonomy.
    @Test func matcherIsAWildcard() throws {
        let data = try StopFailureHook.settingsJSON(dropFile: dropFile)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let entries = try #require(hooks["StopFailure"] as? [[String: Any]])

        #expect(entries.count == 1)
        #expect(entries.first?["matcher"] as? String == "*")
    }

    /// Nothing is shipped for the hook to run: the command is a shell redirect, resolvable anywhere.
    @Test func hookRunsNoShippedHelper() throws {
        let json = String(decoding: try StopFailureHook.settingsJSON(dropFile: dropFile), as: UTF8.self)

        #expect(json.contains(#""type":"command""#))
        #expect(json.contains(#""command":"cat > "#))
    }

    /// A quote in the path would otherwise close the command's string and leave the rest of the path
    /// running as shell.
    @Test func dropFilePathIsQuotedIntoTheCommand() throws {
        let quoted = URL(fileURLWithPath: "/tmp/it's/T.stop-failure.json")
        let json = String(decoding: try StopFailureHook.settingsJSON(dropFile: quoted), as: UTF8.self)

        #expect(json.contains(#"cat > '/tmp/it'\\''s/T.stop-failure.json'"#))
    }

    // MARK: - Reading the payload

    @Test func reportedReasonReadsTheReasonFromThePayload() throws {
        let url = try makeDropFile(#"{"hook_event_name":"StopFailure","reason":"rate_limit"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(StopFailureHook.reportedReason(dropFile: url) == "rate_limit")
    }

    /// Unknown reasons pass through verbatim. The wildcard matcher exists to capture reasons this build
    /// has never heard of, so the reader must not filter them back out.
    @Test func reportedReasonCarriesAnUnknownReasonThrough() throws {
        let url = try makeDropFile(#"{"reason":"something_invented_later"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(StopFailureHook.reportedReason(dropFile: url) == "something_invented_later")
    }

    /// The ordinary case: the hook never fired, so there is no file.
    @Test func reportedReasonIsNilWhenTheDropFileIsAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("StopFailureHookTests-\(UUID().uuidString).json")

        #expect(StopFailureHook.reportedReason(dropFile: missing) == nil)
    }

    /// Every way a present file can fail to say anything reads as the absent file above: truncated
    /// JSON, a payload that isn't an object, no `reason` key, an empty one.
    @Test(arguments: [
        "",
        "not json at all",
        #"{"hook_event_name":"StopFailure","reas"#,
        #"["rate_limit"]"#,
        #"{"hook_event_name":"StopFailure"}"#,
        #"{"reason":""}"#,
        #"{"reason":42}"#,
    ])
    func reportedReasonIsNilForAnUnusablePayload(contents: String) throws {
        let url = try makeDropFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(StopFailureHook.reportedReason(dropFile: url) == nil)
    }
}
