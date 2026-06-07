import Dependencies
import DependenciesMacros
import Foundation
import os
import Store

@DependencyClient
public struct AgentClient: Sendable {
    public var start: @Sendable (StartRequest) async throws -> Session
    public var send: @Sendable (SendRequest) async throws -> Session
}

extension AgentClient: DependencyKey {
    public static var liveValue: AgentClient {
        let impl = LiveAgentClient()
        return AgentClient(
            start: { try await impl.start($0) },
            send: { try await impl.send($0) }
        )
    }
}

extension DependencyValues {
    public var agentClient: AgentClient {
        get { self[AgentClient.self] }
        set { self[AgentClient.self] = newValue }
    }
}

final class LiveAgentClient: Sendable {
    let binaryURL: URL
    private let busySessions = OSAllocatedUnfairLock(initialState: Set<Session.ID>())

    init(binaryURL: URL? = nil) {
        self.binaryURL = binaryURL ?? Self.discoverBinary()
    }

    private static func discoverBinary() -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // HACK: use a config settings screen to have the user input a path
        return URL(fileURLWithPath: "/Users/admin/.local/bin/claude")
    }

    func send(_ request: SendRequest) async throws -> Session {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        let session = request.session

        let alreadyBusy = busySessions.withLock { sessions -> Bool in
            guard !sessions.contains(session.id) else { return true }
            sessions.insert(session.id)
            return false
        }
        if alreadyBusy { throw AgentError.sessionBusy(id: session.id) }
        defer { _ = busySessions.withLock { $0.remove(session.id) } }

        let runner = HarnessRunner(binaryURL: binaryURL)
        try await runner.run(request: request)

        return session
    }

    func start(_ request: StartRequest) async throws -> Session {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        if let inputs = request.inputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: inputs.root.path, isDirectory: &isDir), isDir.boolValue else {
                throw AgentError.inputUnreadable(inputs.root, underlying: CocoaError(.fileReadNoSuchFile))
            }
        }

        let sessionId = Session.ID(rawValue: UUID())
        let session = Session(
            id: sessionId,
            worktree: request.worktree,
            mode: request.mode,
            skillFiles: request.skillFiles,
            addDirs: request.addDirs
        )

        let alreadyBusy = busySessions.withLock { sessions -> Bool in
            guard !sessions.contains(sessionId) else { return true }
            sessions.insert(sessionId)
            return false
        }
        if alreadyBusy { throw AgentError.sessionBusy(id: sessionId) }
        defer { _ = busySessions.withLock { $0.remove(sessionId) } }

        let runner = HarnessRunner(binaryURL: binaryURL)
        try await runner.run(request: request, sessionId: sessionId)

        return session
    }
}
