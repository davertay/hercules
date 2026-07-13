import Foundation
import Testing
import Store

@testable import Agent

@Suite("Session Codable")
struct SessionTests {
    private let id = Session.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let worktree = URL(fileURLWithPath: "/tmp/wt")

    @Test func modeReadOnlyRoundTrips() throws {
        let session = Session(id: id, worktree: worktree, mode: .readOnly, kind: .design)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.mode == .readOnly)
    }

    @Test func kindRoundTrips() throws {
        let session = Session(id: id, worktree: worktree, mode: .readOnly, kind: .allocate)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.kind == .allocate)
    }

    @Test func skillFilesAndAddDirsRoundTrip() throws {
        let session = Session(
            id: id,
            worktree: worktree,
            mode: .write,
            kind: .design,
            skillFiles: [URL(fileURLWithPath: "/skills/grill-me.md")],
            addDirs: [URL(fileURLWithPath: "/skills")]
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.skillFiles == session.skillFiles)
        #expect(decoded.addDirs == session.addDirs)
    }
}
