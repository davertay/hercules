import Foundation

public struct StartRequest: Sendable {
    public let prompt: String
    public let worktree: URL
    public let mode: AgentMode
    public let inputs: InputBundle?
    public let storageRoot: URL

    public init(prompt: String, worktree: URL, mode: AgentMode, inputs: InputBundle? = nil, storageRoot: URL) {
        self.prompt = prompt
        self.worktree = worktree
        self.mode = mode
        self.inputs = inputs
        self.storageRoot = storageRoot
    }
}

public struct SendRequest: Sendable {
    public let prompt: String
    public let session: Session
    public let inputs: InputBundle?

    public init(prompt: String, session: Session, inputs: InputBundle? = nil) {
        self.prompt = prompt
        self.session = session
        self.inputs = inputs
    }
}

public struct InputBundle: Sendable {
    public let root: URL
    public let relativePaths: [String]

    public init(root: URL, relativePaths: [String]) {
        self.root = root
        self.relativePaths = relativePaths
    }
}
