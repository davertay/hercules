import CustomDump
import Foundation
import SnapshotTesting
import SnapshotTestingCustomDump
import Testing

@testable import Agent

@Suite("Harness.renderArgs")
struct HarnessRenderArgsTests {
    let binary = URL(fileURLWithPath: "/usr/local/bin/claude")
    let worktree = URL(fileURLWithPath: "/tmp/wt")
    let inputsRoot = URL(fileURLWithPath: "/tmp/inputs")
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

    @Test func startWriteWithInputs() {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["a.txt", "b.md"])
        let args = Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
            inputs: inputs,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--add-dir"))
        let addDirIdx = args.firstIndex(of: "--add-dir")!
        #expect(args[args.index(after: addDirIdx)] == inputsRoot.path)
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--allowedTools"))
    }

    @Test func resumeReadOnlyWithInputs() {
        let inputs = InputBundle(root: inputsRoot, relativePaths: ["c.swift"])
        let args = Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
            inputs: inputs,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--resume"))
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("--add-dir"))
        let addDirIdx = args.firstIndex(of: "--add-dir")!
        #expect(args[args.index(after: addDirIdx)] == inputsRoot.path)
    }

    @Test func resumeWriteNoInputs() {
        let args = Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .write,
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--resume"))
        let resumeIdx = args.firstIndex(of: "--resume")!
        #expect(args[args.index(after: resumeIdx)] == sessionId.rawValue.uuidString)

        let startArgs = Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .write,
            inputs: nil,
            sessionId: sessionId
        )
        #expect(!startArgs.contains("--resume"))
    }

    @Test func startReadOnlyNoInputs() {
        let args = Harness.renderArgs(
            binary: binary,
            operation: .start,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--allowedTools"))
        let allowedIdx = args.firstIndex(of: "--allowedTools")!
        #expect(args[allowedIdx + 1] == "Read")
        #expect(args[allowedIdx + 2] == "Grep")
        #expect(args[allowedIdx + 3] == "Glob")
        #expect(args[allowedIdx + 4] == "WebFetch")
        #expect(args[allowedIdx + 5] == "WebSearch")
        #expect(!args.contains("--resume"))
    }

    @Test func resumeReadOnlyNoInputs() {
        let args = Harness.renderArgs(
            binary: binary,
            operation: .resume,
            worktree: worktree,
            mode: .readOnly,
            inputs: nil,
            sessionId: sessionId
        )

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: args, as: .customDump)
        }

        #expect(args.contains("--allowedTools"))
        #expect(args.contains("--resume"))
    }
}
