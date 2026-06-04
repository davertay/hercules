import Foundation
import Subprocess
import Testing
import Transcript

@testable import Agent

@Suite("TerminationClassifier — unit")
struct TerminationClassifierTests {
    private func makeWriter() throws -> (TranscriptWriter, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let writer = try TranscriptWriter(url: tempDir.appendingPathComponent("t.jsonl"))
        return (writer, tempDir)
    }

    @Test func cleanExitWritesTurnEnded() throws {
        let (writer, tempDir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try TerminationClassifier().classify(
            status: .exited(0),
            stderrTail: "",
            endedAt: Date(),
            durationMs: 0,
            writer: writer,
            storageRoot: tempDir
        )

        let lines = try String(contentsOf: tempDir.appendingPathComponent("t.jsonl"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let parsed = try parseTranscriptLine(Data(String(lines.last!).utf8))
        if case .hercules(.turnEnded) = parsed {} else {
            Issue.record("Expected hercules.turn.ended, got: \(String(lines.last!))")
        }
    }

    @Test func nonZeroExitThrowsHarnessFailed() throws {
        let (writer, tempDir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try TerminationClassifier().classify(
                status: .exited(2),
                stderrTail: "boom",
                endedAt: Date(),
                durationMs: 0,
                writer: writer,
                storageRoot: tempDir
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessFailed(let exitCode, let tail) = err else {
                Issue.record("Expected .harnessFailed, got \(err)")
                return
            }
            #expect(exitCode == 2)
            #expect(tail == "boom")
        }
    }

    @Test func nonZeroExitWithMalformedLineThrowsMalformedStream() throws {
        let (writer, tempDir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        struct Dummy: Error {}
        do {
            try TerminationClassifier().classify(
                status: .exited(1),
                lastMalformedLine: (raw: "not json", error: Dummy()),
                stderrTail: "",
                endedAt: Date(),
                durationMs: 0,
                writer: writer,
                storageRoot: tempDir
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .malformedStream(let line, _) = err else {
                Issue.record("Expected .malformedStream, got \(err)")
                return
            }
            #expect(line == "not json")
        }
    }

    @Test func signalTerminationThrowsHarnessCrashed() throws {
        let (writer, tempDir) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try TerminationClassifier().classify(
                status: .signaled(15),
                stderrTail: "",
                endedAt: Date(),
                durationMs: 0,
                writer: writer,
                storageRoot: tempDir
            )
            Issue.record("Expected throw")
        } catch let err as AgentError {
            guard case .harnessCrashed(let signal, _) = err else {
                Issue.record("Expected .harnessCrashed, got \(err)")
                return
            }
            #expect(signal == 15)
        }
    }
}
