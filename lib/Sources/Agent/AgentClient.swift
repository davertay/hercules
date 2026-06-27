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
    /// A fixed binary, used by the IOTests seam. When `nil`, the binary is resolved fresh from the
    /// current `AppConfig` at the top of each `start`/`send`.
    private let binaryOverride: URL?
    private let busySessions = OSAllocatedUnfairLock(initialState: Set<Session.ID>())

    init(binaryURL: URL? = nil) {
        self.binaryOverride = binaryURL
    }

    /// Resolves the harness binary and the user's extra CLI arguments for a run. Reads a fresh
    /// `AppConfig` each call so a Settings change applies on the next run without restarting the app
    /// (per ADR 0001's fresh-Harness-per-Turn boundary). The test seam's fixed binary short-circuits
    /// resolution and carries no extra arguments.
    private func resolveHarness() -> (binary: URL, extraArguments: [ExtraArgument]) {
        if let binaryOverride { return (binaryOverride, []) }
        @Dependency(\.appConfigClient) var appConfigClient
        let config = appConfigClient.load()
        let binary = HarnessBinaryResolver.resolve(
            configuredPath: config.agentExecutablePath,
            lookup: { HarnessBinaryResolver.pathLookup() }
        )
        return (binary, config.extraArguments)
    }

    func send(_ request: SendRequest) async throws -> Session {
        let (binaryURL, extraArguments) = resolveHarness()
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

        let runner = HarnessRunner(binaryURL: binaryURL, extraArguments: extraArguments)
        try await runner.run(request: request)

        return session
    }

    func start(_ request: StartRequest) async throws -> Session {
        let (binaryURL, extraArguments) = resolveHarness()
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        if let inputs = request.inputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: inputs.root.path, isDirectory: &isDir), isDir.boolValue else {
                throw AgentError.inputUnreadable(inputs.root, underlying: CocoaError(.fileReadNoSuchFile))
            }
        }

        let sessionId = Session.ID(rawValue: request.sessionID ?? UUID())
        let session = Session(
            id: sessionId,
            worktree: request.worktree,
            mode: request.mode,
            kind: request.kind,
            skillFiles: request.skillFiles,
            addDirs: request.addDirs,
            mcpServers: request.mcpServers
        )

        let alreadyBusy = busySessions.withLock { sessions -> Bool in
            guard !sessions.contains(sessionId) else { return true }
            sessions.insert(sessionId)
            return false
        }
        if alreadyBusy { throw AgentError.sessionBusy(id: sessionId) }
        defer { _ = busySessions.withLock { $0.remove(sessionId) } }

        let runner = HarnessRunner(binaryURL: binaryURL, extraArguments: extraArguments)
        try await runner.run(request: request, sessionId: sessionId)

        return session
    }
}
