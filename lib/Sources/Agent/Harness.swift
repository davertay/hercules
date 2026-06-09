import Foundation
import Store

public enum Harness {
    public enum Operation: Sendable {
        case start
        case resume
    }

    public static func renderArgs(
        binary: URL,
        operation: Operation,
        worktree: URL,
        mode: AgentMode,
        inputs: InputBundle?,
        skillFiles: [URL] = [],
        addDirs: [URL] = [],
        sessionId: Session.ID
    ) -> [String] {
        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            // Realtime streaming input keeps stdin open so we can send a control_request (an
            // interrupt) mid-Turn when the agent asks a question. The prompt is sent as a
            // stream-json user message; see `SubProcess`.
            "--input-format", "stream-json",
            "--permission-mode", "bypassPermissions",
            "--setting-sources", "user,project,local",
            "--verbose",
            "--include-partial-messages",
        ]

        switch operation {
        case .start:
            args += ["--session-id", sessionId.rawValue.uuidString]
        case .resume:
            args += ["--resume", sessionId.rawValue.uuidString]
        }

        if mode == .readOnly {
            args += ["--allowedTools", "Read", "Grep", "Glob", "WebFetch", "WebSearch"]
        }

        if let inputs {
            args += ["--add-dir", inputs.root.path]
        }

        for dir in addDirs {
            args += ["--add-dir", dir.path]
        }

        for file in skillFiles {
            args += ["--append-system-prompt-file", file.path]
        }

        return args
    }

    static func renderPrompt(prompt: String, inputs: InputBundle?) -> String {
        guard let inputs, !inputs.relativePaths.isEmpty else {
            return prompt
        }
        let footer = inputs.relativePaths.map { "- \($0)" }.joined(separator: "\n")
        return "\(prompt)\n\nFiles available (read with your file-read tool):\n\(footer)"
    }
}
