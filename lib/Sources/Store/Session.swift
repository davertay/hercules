import Foundation

public struct Session: Codable, Sendable, Hashable, Identifiable {
    public let id: ID
    public let worktree: URL
    public let mode: AgentMode
    public let dataDir: URL

    public var transcript: URL {
        dataDir.appendingPathComponent("transcript.jsonl")
    }

    public init(id: ID, worktree: URL, mode: AgentMode, dataDir: URL) {
        self.id = id
        self.worktree = worktree
        self.mode = mode
        self.dataDir = dataDir
    }

    public struct ID: Codable, Sendable, Hashable, RawRepresentable {
        public let rawValue: UUID

        public init(rawValue: UUID) {
            self.rawValue = rawValue
        }
    }
}
