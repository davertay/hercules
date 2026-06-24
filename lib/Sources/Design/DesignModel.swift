import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Design Phase: a `ChatEngine` conversation plus orchestration to generate the summary
/// Artifact and record the Phase complete.
@MainActor
@Observable
public final class DesignModel {
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The Design summary Artifact is written beneath this at `phases/design/summary.md`.
    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    /// Set once a finalization Turn writes the summary; cleared when new chat activity starts.
    public var summarySavedURL: URL?

    public init(worktree: URL, workflowID: UUID, workflowDirectory: URL, database: any DatabaseWriter) {
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.database = database
        self.skill = loadSkill(.grillMe)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .design,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        // Dismiss the saved-summary confirmation the moment the user sends a new message.
        engine.onSend = { [weak self] in self?.summarySavedURL = nil }
    }

    public var isIntake: Bool { engine.isIntake }

    /// Whether this Phase's chat agent is mid-Turn — the Design contribution to the Workflow's aggregate
    /// running state. A thin reflection of the engine's run flag.
    public var isBusy: Bool { engine.isRunning }

    public var isGenerateSummaryAvailable: Bool {
        engine.session != nil
    }

    static let finalizationPrompt = "Produce the complete design summary now as a markdown document."

    /// Writes the finalization Turn's answer to `phases/design/summary.md` and completes the Phase.
    /// Re-running overwrites the file and updates the same row.
    public func generateSummary() {
        guard let session = engine.session, !engine.isRunning else { return }
        engine.errorText = nil
        summarySavedURL = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                try await engine.send(Self.finalizationPrompt)
                let finalAnswer = try database.latestFinalAnswer(forSession: session.id.rawValue) ?? ""
                let url = try writeSummary(finalAnswer)
                try database.completePhase(
                    workflowID: workflowID, kind: "design", artifactPath: url.path,
                    id: uuid(), now: now
                )
                summarySavedURL = url
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    private func writeSummary(_ markdown: String) throws -> URL {
        let url = workflowDirectory
            .appending(path: "phases/design", directoryHint: .isDirectory)
            .appending(path: "summary.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
