import Agent
import Chat
import Dependencies
import Foundation
import Material
import Observation
import SQLiteData
import Store

/// Drives the Design Phase. The chat itself is owned by a `ChatEngine` configured to start a
/// `readOnly` Session under the bundled grill-me Skill with the repo as cwd; this model layers the
/// Design-specific Phase orchestration on top — generating the summary Artifact and recording the
/// Phase as complete.
@MainActor
@Observable
public final class DesignModel {
    /// The shared chat engine, configured for Design's Session. Owned here and handed to the chat
    /// views; Design adds nothing to its conversation rendering.
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    /// The Workflow's root directory (`~/.hercules/workflows/<id>/`); the Design summary Artifact is
    /// written beneath it at `phases/design/summary.md`.
    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    /// The saved summary's location once a finalization Turn has written it. Drives the saved
    /// confirmation (with its Reveal in Finder button); cleared when new chat activity starts.
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
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        // Dismiss the saved-summary confirmation the moment the user sends a new message.
        engine.onSend = { [weak self] in self?.summarySavedURL = nil }
    }

    /// True before any conversation exists — drives the intake prompt instead of the transcript.
    public var isIntake: Bool { engine.isIntake }

    public var isGenerateSummaryAvailable: Bool {
        engine.session != nil
    }

    /// The canned instruction the finalization Turn resumes the Session with.
    static let finalizationPrompt = "Produce the complete design summary now as a markdown document."

    /// Resumes the Session with the finalization instruction, then writes that Turn's final answer to
    /// `phases/design/summary.md` and flips the Design `phase` row to complete with the Artifact path.
    /// Re-running overwrites the file and updates the same row.
    public func generateSummary() {
        guard let session = engine.session, !engine.isRunning else { return }
        engine.errorText = nil
        summarySavedURL = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                try await engine.send(Self.finalizationPrompt)
                let url = try writeSummary(finalAnswer(forSession: session.id.rawValue))
                try recordDesignComplete(artifactPath: url.path)
                summarySavedURL = url
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    /// The final answer of the Session's most recent Turn — the finalization Turn just projected.
    private func finalAnswer(forSession sessionID: UUID) throws -> String {
        let turn = try database.read { db in
            try TurnRow
                .where { $0.sessionID.eq(sessionID) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }
        return turn?.finalAnswer ?? ""
    }

    /// Writes the summary markdown to `phases/design/summary.md` under the Workflow directory,
    /// creating the intermediate directories and overwriting any existing file.
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

    /// Flips the Design `phase` row to complete with the Artifact path, inserting the row the first
    /// time and updating it on a re-run.
    private func recordDesignComplete(artifactPath: String) throws {
        let timestamp = now
        try database.write { db in
            let existing = try PhaseRow
                .where { $0.workflowID.eq(workflowID) }
                .where { $0.kind.eq("design") }
                .fetchOne(db)
            if let existing {
                try PhaseRow
                    .find(existing.id)
                    .update {
                        $0.status = "complete"
                        $0.artifactPath = #bind(artifactPath)
                        $0.updatedAt = timestamp
                    }
                    .execute(db)
            } else {
                try PhaseRow.insert {
                    PhaseRow(
                        id: uuid(),
                        workflowID: workflowID,
                        kind: "design",
                        status: "complete",
                        artifactPath: artifactPath,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)
            }
        }
    }
}
