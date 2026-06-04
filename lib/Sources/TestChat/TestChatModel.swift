import Foundation
import Observation

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

    public let worktree: URL

    var isRunning = false
    var draftText = ""

    private var runTask: Task<Void, Never>?

    var messages: [ChatMessage] = [
        ChatMessage(
            role: .user,
            text: "What can you tell me about this folder?"
        ),
        ChatMessage(
            role: .assistant,
            text: "Here is a **stub reply** demonstrating markdown:\n\n- **Bold** and _italic_ text render correctly.\n- `Code spans` are supported.\n\nThis is placeholder data. No real agent has been invoked."
        ),
    ]

    public init(worktree: URL) {
        self.worktree = worktree
    }

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
        runTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.messages.append(ChatMessage(
                role: .assistant,
                text: "**Placeholder reply** to:\n\n> \(prompt)\n\n_No real agent was invoked. All content is stub data._",
                isError: prompt.contains("error")
            ))
            self.isRunning = false
        }
    }

    func tearDown() {
        runTask?.cancel()
    }
}
