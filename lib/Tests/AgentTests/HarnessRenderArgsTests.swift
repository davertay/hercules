import CustomDump
import SnapshotTesting
import Testing

@testable import Agent

@Suite("Harness.renderArgs")
struct HarnessRenderArgsTests {
    let binary = URL(fileURLWithPath: "/usr/local/bin/claude")
    let worktree = URL(fileURLWithPath: "/tmp/wt")
    let sessionId = Session.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test func startWriteNoInputs() {
        let args = Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--output-format"))
        let outputFormatIdx = args.firstIndex(of: "--output-format")!
        #expect(args[args.index(after: outputFormatIdx)] == "stream-json")

        #expect(args.contains("--session-id"))
        let sessionIdIdx = args.firstIndex(of: "--session-id")!
        #expect(args[args.index(after: sessionIdIdx)] == sessionId.rawValue.uuidString)

        #expect(!args.contains("--resume"))
        #expect(!args.contains("--allowedTools"))
    }
}
