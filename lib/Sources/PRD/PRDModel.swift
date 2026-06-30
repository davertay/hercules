import Agent
import Chat
import Dependencies
import Foundation
import Skills
import Observation
import SQLiteData
import Store

/// Drives the PRD Phase: a directed one-shot rather than a conversation. One directed Turn consumes
/// the Design summary as an input, writes the PRD Artifact, and records the Phase complete.
@MainActor
@Observable
public final class PRDModel {
    let engine: ChatEngine

    @ObservationIgnored
    @Dependency(\.uuid) private var uuid

    @ObservationIgnored
    @Dependency(\.date.now) private var now

    @ObservationIgnored
    private let database: any DatabaseWriter

    @ObservationIgnored
    private let workflowID: UUID

    @ObservationIgnored
    private let workflowDirectory: URL

    @ObservationIgnored
    private let skill: SkillResource

    @ObservationIgnored
    @Fetch var prdPhase: PhaseRow?

    @ObservationIgnored
    var runTask: Task<Void, Never>?

    public init(worktree: URL, workflowID: UUID, workflowDirectory: URL, database: any DatabaseWriter) {
        self.workflowID = workflowID
        self.workflowDirectory = workflowDirectory
        self.database = database
        self.skill = loadSkill(.toPrd)
        self.engine = ChatEngine(
            worktree: worktree,
            mode: .readOnly,
            workflowID: workflowID,
            kind: .prd,
            skillFiles: [skill.fileUrl],
            addDirs: [skill.folderUrl],
            database: database
        )
        _prdPhase = Fetch(
            wrappedValue: nil,
            CompletedPRDPhaseRequest(workflowID: workflowID),
            animation: .default
        )
    }

    public var prdSavedURL: URL? {
        prdPhase?.artifactPath.map { URL(fileURLWithPath: $0) }
    }

    public var isComplete: Bool { prdPhase != nil }

    public var isSkipped: Bool { isComplete && prdSavedURL == nil }

    public var isIdle: Bool { engine.isIntake }

    public var isBusy: Bool { engine.isRunning }

    public func cancel() {
        engine.cancel()
    }

    public var isGenerateAvailable: Bool {
        !engine.isRunning && !isComplete
    }

    public var isRegenerateAvailable: Bool {
        !engine.isRunning && prdSavedURL != nil
    }

    static func directedPrompt(summaryPath: String) -> String {
        "Read the Design summary at \(summaryPath) and produce the complete PRD now as a markdown document."
    }

    static func regeneratePrompt(summaryPath: String) -> String {
        """
        Re-read the Design summary at \(summaryPath) — it may have been revised since the last \
        run — and produce the complete PRD again as a markdown document.
        """
    }

    public func skip() {
        guard isGenerateAvailable else { return }
        do {
            try database.completePhase(workflowID: workflowID, kind: "prd", id: uuid(), now: now)
        } catch {
            engine.errorText = error.localizedDescription
        }
    }

    public func unskip() {
        guard isSkipped else { return }
        do {
            try database.reopenPhase(workflowID: workflowID, kind: "prd", now: now)
        } catch {
            engine.errorText = error.localizedDescription
        }
    }

    public func generate() {
        guard isGenerateAvailable else { return }
        runDirectedTurn(prompt: Self.directedPrompt(summaryPath:))
    }

    public func regenerate() {
        guard isRegenerateAvailable else { return }
        runDirectedTurn(prompt: Self.regeneratePrompt(summaryPath:))
    }

    private func runDirectedTurn(prompt: @escaping (String) -> String) {
        engine.errorText = nil
        engine.isRunning = true

        runTask = Task { [self] in
            do {
                let summaryURL = try designSummaryURL()
                try await engine.send(
                    prompt(summaryURL.path),
                    inputs: InputBundle(
                        root: summaryURL.deletingLastPathComponent(),
                        relativePaths: [summaryURL.lastPathComponent]
                    )
                )
                guard let session = engine.session else { throw PRDError.sessionUnavailable }
                let finalAnswer = try database.latestFinalAnswer(forSession: session.id.rawValue) ?? ""
                let url = try writePRD(finalAnswer)
                try database.completePhase(
                    workflowID: workflowID, kind: "prd", artifactPath: url.path,
                    id: uuid(), now: now
                )
            } catch {
                engine.errorText = error.localizedDescription
            }
            engine.isRunning = false
        }
    }

    private func designSummaryURL() throws -> URL {
        guard let path = try database.completedArtifactPath(workflowID: workflowID, kind: "design")
        else { throw PRDError.designSummaryMissing }
        return URL(fileURLWithPath: path)
    }

    private func writePRD(_ markdown: String) throws -> URL {
        let url = workflowDirectory
            .appending(path: "phases/prd", directoryHint: .isDirectory)
            .appending(path: "prd.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum PRDError: LocalizedError {
    case designSummaryMissing
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .designSummaryMissing:
            "The completed Design Phase's summary could not be found."
        case .sessionUnavailable:
            "The PRD Session could not be started."
        }
    }
}

struct CompletedPRDPhaseRequest: FetchKeyRequest {
    var workflowID: UUID = UUID()

    func fetch(_ db: Database) throws -> PhaseRow? {
        try completedPhaseRow(db, workflowID: workflowID, kind: "prd")
    }
}
