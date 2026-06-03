import Foundation

public enum TranscriptLine: Sendable {
    case hercules(HerculesEvent)
    case harness(rawJSON: Data)
}

public enum HerculesEvent: Codable, Sendable {
    case sessionStarted(SessionStarted)
    case turnStarted(TurnStarted)
    case turnEnded(TurnEnded)
    case turnFailed(TurnFailed)

    public struct SessionStarted: Codable, Sendable {
        public let sessionId: Session.ID
        public let worktree: URL
        public let mode: AgentMode
        public let attachedFiles: [String]
        public let startedAt: Date

        enum CodingKeys: String, CodingKey {
            case type, sessionId, worktree, mode, attachedFiles, startedAt
        }

        public init(sessionId: Session.ID, worktree: URL, mode: AgentMode, attachedFiles: [String], startedAt: Date) {
            self.sessionId = sessionId
            self.worktree = worktree
            self.mode = mode
            self.attachedFiles = attachedFiles
            self.startedAt = startedAt
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(Session.ID.self, forKey: .sessionId)
            worktree = try c.decode(URL.self, forKey: .worktree)
            mode = try c.decode(AgentMode.self, forKey: .mode)
            attachedFiles = try c.decode([String].self, forKey: .attachedFiles)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("hercules.session.started", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktree, forKey: .worktree)
            try c.encode(mode, forKey: .mode)
            try c.encode(attachedFiles, forKey: .attachedFiles)
            try c.encode(startedAt, forKey: .startedAt)
        }
    }

    public struct TurnStarted: Codable, Sendable {
        public let userPrompt: String
        public let attachedFiles: [String]
        public let startedAt: Date

        enum CodingKeys: String, CodingKey {
            case type, userPrompt, attachedFiles, startedAt
        }

        public init(userPrompt: String, attachedFiles: [String], startedAt: Date) {
            self.userPrompt = userPrompt
            self.attachedFiles = attachedFiles
            self.startedAt = startedAt
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userPrompt = try c.decode(String.self, forKey: .userPrompt)
            attachedFiles = try c.decode([String].self, forKey: .attachedFiles)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("hercules.turn.started", forKey: .type)
            try c.encode(userPrompt, forKey: .userPrompt)
            try c.encode(attachedFiles, forKey: .attachedFiles)
            try c.encode(startedAt, forKey: .startedAt)
        }
    }

    public struct TurnEnded: Codable, Sendable {
        public let endedAt: Date
        public let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case type, endedAt, durationMs
        }

        public init(endedAt: Date, durationMs: Int) {
            self.endedAt = endedAt
            self.durationMs = durationMs
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            endedAt = try c.decode(Date.self, forKey: .endedAt)
            durationMs = try c.decode(Int.self, forKey: .durationMs)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("hercules.turn.ended", forKey: .type)
            try c.encode(endedAt, forKey: .endedAt)
            try c.encode(durationMs, forKey: .durationMs)
        }
    }

    public struct TurnFailed: Codable, Sendable {
        public let endedAt: Date
        public let durationMs: Int
        public let errorKind: String
        public let errorMessage: String

        enum CodingKeys: String, CodingKey {
            case type, endedAt, durationMs, errorKind, errorMessage
        }

        public init(endedAt: Date, durationMs: Int, errorKind: String, errorMessage: String) {
            self.endedAt = endedAt
            self.durationMs = durationMs
            self.errorKind = errorKind
            self.errorMessage = errorMessage
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            endedAt = try c.decode(Date.self, forKey: .endedAt)
            durationMs = try c.decode(Int.self, forKey: .durationMs)
            errorKind = try c.decode(String.self, forKey: .errorKind)
            errorMessage = try c.decode(String.self, forKey: .errorMessage)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("hercules.turn.failed", forKey: .type)
            try c.encode(endedAt, forKey: .endedAt)
            try c.encode(durationMs, forKey: .durationMs)
            try c.encode(errorKind, forKey: .errorKind)
            try c.encode(errorMessage, forKey: .errorMessage)
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hercules.session.started":
            self = .sessionStarted(try SessionStarted(from: decoder))
        case "hercules.turn.started":
            self = .turnStarted(try TurnStarted(from: decoder))
        case "hercules.turn.ended":
            self = .turnEnded(try TurnEnded(from: decoder))
        case "hercules.turn.failed":
            self = .turnFailed(try TurnFailed(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: TypeKey.type, in: c,
                debugDescription: "Unknown hercules event type"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .sessionStarted(let v): try v.encode(to: encoder)
        case .turnStarted(let v): try v.encode(to: encoder)
        case .turnEnded(let v): try v.encode(to: encoder)
        case .turnFailed(let v): try v.encode(to: encoder)
        }
    }
}
