import Foundation
import Testing

@testable import Agent

@Suite("HarnessBinaryResolver")
struct HarnessBinaryResolverTests {
    @Test func configuredPathWins() {
        let resolved = HarnessBinaryResolver.resolve(
            configuredPath: "/opt/claude",
            lookup: { URL(fileURLWithPath: "/from/path/claude") }
        )
        #expect(resolved == URL(fileURLWithPath: "/opt/claude"))
    }

    @Test func emptyConfiguredPathFallsThroughToLookup() {
        let found = URL(fileURLWithPath: "/from/path/claude")
        let resolved = HarnessBinaryResolver.resolve(
            configuredPath: nil,
            lookup: { found }
        )
        #expect(resolved == found)
    }

    @Test func whitespaceConfiguredPathFallsThroughToLookup() {
        let found = URL(fileURLWithPath: "/from/path/claude")
        let resolved = HarnessBinaryResolver.resolve(
            configuredPath: "   ",
            lookup: { found }
        )
        #expect(resolved == found)
    }

    @Test func noConfigAndNoLookupYieldsUnresolvedPlaceholder() {
        let resolved = HarnessBinaryResolver.resolve(
            configuredPath: nil,
            lookup: { nil }
        )
        #expect(resolved == HarnessBinaryResolver.unresolved)
        // The placeholder must fail the executability guard, so a misconfigured run surfaces as
        // AgentError.harnessNotFound rather than silently launching something.
        #expect(!FileManager.default.isExecutableFile(atPath: resolved.path))
    }

    @Test func noHACKFallback() {
        let resolved = HarnessBinaryResolver.resolve(configuredPath: nil, lookup: { nil })
        #expect(resolved.path != "/Users/admin/.local/bin/claude")
    }

    @Test func pathLookupFindsExecutableOnPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appending(component: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let found = HarnessBinaryResolver.pathLookup(environment: ["PATH": dir.path])
        #expect(found == binary)
    }

    @Test func pathLookupReturnsNilWhenAbsent() {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
        #expect(HarnessBinaryResolver.pathLookup(environment: ["PATH": dir.path]) == nil)
    }
}
