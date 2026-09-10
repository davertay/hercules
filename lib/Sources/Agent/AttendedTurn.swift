import Foundation
import Store

/// What an *attended* Turn — one a human is watching — carries over one nobody is watching: the MCP
/// server that serves `ask_user`, and the house-rules document that tells the model the tool is there
/// and how to read what comes back.
///
/// The two are one value with one way to attach them because either alone is a silent failure. A tool
/// nobody told the model about is never called, and an instruction to call a tool that was never
/// configured is an instruction to call nothing — and both fail by the agent quietly carrying on
/// without the answer it needed. Nothing here hands out one half.
struct AttendedTurn {
    /// This Turn's question channel: the directory the spawned server announces its calls in, and the
    /// only thing about the Turn the bundle needs to know.
    let channelDirectory: URL

    /// Adds both halves to the Turn's configuration.
    ///
    /// The house rules ride `skillFiles` — composed after the Skill into the Turn's one appended system
    /// prompt (ADR 0004) — rather than being edited into each Skill. A Skill describes what a Phase's
    /// agent is for; this describes the environment the Harness is running in, so it attaches per
    /// Session and an attended Turn reads the same rules whichever Skill is driving the Phase.
    func attach(to configuration: inout Harness.SessionConfiguration) {
        configuration.mcpServers.append(
            .questionAsker(command: HerculesMCP.serverCommand, channelDirectory: channelDirectory)
        )
        configuration.skillFiles.append(Self.houseRules)
    }

    /// The bundled house rules. Absent, every attended Turn would run unsteered and ask its questions as
    /// prose again, so a missing document is a broken build rather than a condition to handle — the same
    /// call the Skills make about theirs.
    static let houseRules: URL = {
        let url = Bundle.module.url(
            forResource: "attended-house-rules",
            withExtension: "md",
            subdirectory: "Resources"
        )
        guard let url else {
            preconditionFailure("Missing the attended house-rules document")
        }
        return url
    }()
}
