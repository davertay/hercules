import Dependencies
import DependenciesMacros
import Foundation
import os

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
        return URL(fileURLWithPath: "/usr/local/bin/claude")
    }

    func send(_ request: SendRequest) async throws -> Session {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        let session = request.session

        let writer: TranscriptWriter
        do {
            writer = try TranscriptWriter(url: session.transcript, append: true)
        } catch {
            throw AgentError.transcriptIOFailed(session.transcript, underlying: error)
        }

        busySessions.withLock { $0.insert(session.id) }
        defer { busySessions.withLock { $0.remove(session.id) } }

        let runner = HarnessRunner(binaryURL: binaryURL)
        try await runner.run(request: request, writer: writer)

        return session
    }

    func start(_ request: StartRequest) async throws -> Session {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw AgentError.harnessNotFound(triedPath: binaryURL)
        }

        let sessionId = Session.ID(rawValue: UUID())
        let dataDir = request.storageRoot.appendingPathComponent(sessionId.rawValue.uuidString)

        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: false)
        } catch let e as CocoaError where e.code == .fileWriteFileExists {
            throw AgentError.dataDirectoryExists(dataDir)
        } catch {
            throw AgentError.transcriptIOFailed(dataDir, underlying: error)
        }

        let session = Session(id: sessionId, worktree: request.worktree, mode: request.mode, dataDir: dataDir)

        let writer: TranscriptWriter
        do {
            writer = try TranscriptWriter(url: session.transcript)
        } catch {
            throw AgentError.transcriptIOFailed(session.transcript, underlying: error)
        }

        busySessions.withLock { $0.insert(sessionId) }
        defer { busySessions.withLock { $0.remove(sessionId) } }

        let runner = HarnessRunner(binaryURL: binaryURL)
        try await runner.run(request: request, sessionId: sessionId, writer: writer)

        return session
    }
}
