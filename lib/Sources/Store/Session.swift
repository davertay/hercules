import Foundation

public struct Session: Codable, Sendable, Hashable, Identifiable {
    public let id: ID
    public let worktree: URL
    public let mode: AgentMode
    /// The surface this Session serves; scopes its Turns to one Chat (ADR 0005).
    public let kind: SessionKind
    /// Skill prompt files pinned at Session start; re-passed on every resume Turn (ADR 0004).
    public let skillFiles: [URL]
    /// Directories exposed to the Harness via `--add-dir`, pinned alongside the skill files so a
    /// resumed Turn can still read the supporting files a pinned skill references.
    public let addDirs: [URL]

    public init(
        id: ID,
        worktree: URL,
        mode: AgentMode,
        kind: SessionKind,
        skillFiles: [URL] = [],
        addDirs: [URL] = []
    ) {
        self.id = id
        self.worktree = worktree
        self.mode = mode
        self.kind = kind
        self.skillFiles = skillFiles
        self.addDirs = addDirs
    }

    public struct ID: Codable, Sendable, Hashable, RawRepresentable {
        public let rawValue: UUID

        public init(rawValue: UUID) {
            self.rawValue = rawValue
        }
    }
}
