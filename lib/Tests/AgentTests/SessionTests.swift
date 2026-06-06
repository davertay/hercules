import Foundation
import Testing
import Store

@testable import Agent

@Suite("Session Codable")
struct SessionTests {
    private let id = Session.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let worktree = URL(fileURLWithPath: "/tmp/wt")
    private let dataDir = URL(fileURLWithPath: "/tmp/data")

    @Test func modeReadOnlyRoundTrips() throws {
        let session = Session(id: id, worktree: worktree, mode: .readOnly, dataDir: dataDir)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.mode == .readOnly)
    }
}
