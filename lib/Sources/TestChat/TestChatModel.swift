import Agent
import Dependencies
import Foundation
import Observation
import Transcript

@MainActor
@Observable
public final class TestChatModel {
    struct ChatMessage: Identifiable, Sendable {
        let id: UUID
        enum Role: Sendable { case user, assistant }
        let role: Role
        let text: String
        let isError: Bool

        init(role: Role, text: String, isError: Bool = false) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.isError = isError
        }
    }

    @ObservationIgnored
    @Dependency(\.agentClient) var agentClient: AgentClient

    @ObservationIgnored
    private let teardown: TeardownHandle

    private var session: Session?
    var runTask: Task<Void, Never>? { teardown.runTask }

    var isRunning = false
    var draftText = ""
    var messages: [ChatMessage] = []

    public let worktree: URL

    public init(worktree: URL) {
        self.worktree = worktree
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        self.teardown = TeardownHandle(storageRoot: storageRoot)
    }

    // Exposed internally so tests can observe cleanup without publishing it as API.
    var storageRoot: URL { teardown.storageRoot }

    var windowTitle: String {
        "Test Chat: \(worktree.lastPathComponent)"
    }

    var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning
    }

    func submit() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        draftText = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        isRunning = true
        teardown.runTask = Task {
            do {
                let completedSession: Session
                if let existing = session {
                    completedSession = try await agentClient.send(
                        SendRequest(prompt: prompt, session: existing)
                    )
                } else {
                    completedSession = try await agentClient.start(
                        StartRequest(
                            prompt: prompt,
                            worktree: worktree,
                            mode: .readOnly,
                            storageRoot: teardown.storageRoot
                        )
                    )
                    session = completedSession
                }
                messages = rebuildMessages(from: completedSession.transcript)
            } catch {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    isError: true
                ))
            }
            isRunning = false
        }
    }

    func tearDown() {
        teardown.runTask?.cancel()
        try? FileManager.default.removeItem(at: teardown.storageRoot)
    }

    private func rebuildMessages(from transcriptURL: URL) -> [ChatMessage] {
        guard let contents = try? Data(contentsOf: transcriptURL) else { return messages }
        var rebuilt: [ChatMessage] = []
        for lineData in contents.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let line = try? parseTranscriptLine(Data(lineData)) else { continue }
            switch line {
            case .hercules(let event):
                switch event {
                case .sessionStarted, .turnEnded:
                    break
                case .turnStarted(let ts):
                    rebuilt.append(ChatMessage(role: .user, text: ts.userPrompt))
                case .turnFailed(let tf):
                    rebuilt.append(ChatMessage(role: .assistant, text: tf.errorMessage, isError: true))
                }
            case .harness(let rawJSON):
                if let result = decodeHarnessResult(rawJSON) {
                    rebuilt.append(ChatMessage(role: .assistant, text: result.text, isError: result.isError))
                }
            }
        }
        return rebuilt
    }
}

// Holds cleanup state so that deinit can cancel the in-flight task and remove
// the storage directory even if tearDown() was never called (missed signal).
// @unchecked Sendable: mutation is confined to @MainActor; deinit runs after
// the last strong reference drops, at which point no @MainActor code can reach
// these fields.
private final class TeardownHandle: @unchecked Sendable {
    var runTask: Task<Void, Never>?
    let storageRoot: URL

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    deinit {
        runTask?.cancel()
        try? FileManager.default.removeItem(at: storageRoot)
    }
}
