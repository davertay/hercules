import Foundation
import Store
import Testing

@testable import Agent

/// The bundle an attended Turn carries: the server that serves the question tool, and the house rules
/// that tell the model it is there. Both halves, or neither.
@Suite("The attended bundle")
struct AttendedTurnTests {
    private let channelDirectory = URL(fileURLWithPath: "/tmp/AttendedTurnTests/a1.questions")
    private let skill = URL(fileURLWithPath: "/skills/grill-me/SKILL.md")
    private let writer = MCPServer.artifactWriter(
        command: "/path/to/Hercules",
        artifactURL: URL(fileURLWithPath: "/tmp/wf/phases/design/summary.md")
    )

    /// Attaching adds one to each list and disturbs neither — the Phase's own Skill and whatever servers
    /// the Turn already carried are still there, in front of what the bundle adds.
    @Test func attachingAddsTheServerAndTheHouseRulesTogether() {
        var configuration = Harness.SessionConfiguration(
            worktree: URL(fileURLWithPath: "/tmp/wt"),
            mode: .readOnly,
            skillFiles: [skill],
            mcpServers: [writer]
        )

        AttendedTurn(channelDirectory: channelDirectory).attach(to: &configuration)

        #expect(configuration.skillFiles == [skill, AttendedTurn.houseRules])
        #expect(configuration.mcpServers.map(\.name) == [writer.name, "hercules_ask"])
        #expect(configuration.mcpServers.last?.args.contains(channelDirectory.path) == true)
    }

    /// The document ships in the bundle. A missing one would leave every attended Turn unsteered, which
    /// is the failure this half of the bundle exists to prevent.
    @Test func theHouseRulesAreBundledAndReadable() throws {
        #expect(FileManager.default.fileExists(atPath: AttendedTurn.houseRules.path))
        #expect(!(try Self.houseRules().isEmpty))
    }

    /// The load-bearing line. MCP tools are deferred rather than listed up front, so the model reaches
    /// this one by searching for its exact name — and the name it is told is the one the descriptor it
    /// arrives with actually configures, rather than a copy that can drift from it.
    @Test func theHouseRulesNameTheToolTheDescriptorConfigures() throws {
        let asker = MCPServer.questionAsker(command: "/path/to/Hercules", channelDirectory: channelDirectory)
        let qualified = try #require(asker.qualifiedToolNames.first)

        #expect(qualified == "mcp__hercules_ask__ask_user")
        #expect(try Self.houseRules().contains(qualified))
    }

    /// The other three things the document has to say: ask no other way, what comes back, and that a
    /// dismissed question is not to be asked again in the same Turn.
    @Test func theHouseRulesCoverAskingAnsweringAndCancelling() throws {
        let rules = try Self.houseRules()

        #expect(rules.contains("any other way"))
        #expect(rules.contains(#"{"answers""#))
        #expect(rules.contains("selected") && rules.contains("note") && rules.contains("header"))
        // The one thing the spike never exercised: a selection is not an unqualified endorsement of the
        // option as the model worded it.
        #expect(rules.contains("qualifies or overrides"))
        #expect(rules.contains("again in this turn"))
    }

    private static func houseRules() throws -> String {
        try String(contentsOf: AttendedTurn.houseRules, encoding: .utf8)
    }
}
