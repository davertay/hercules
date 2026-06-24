import Foundation
import Testing

@testable import Agent

@Suite("SubProcess.augmentedPath")
struct SubProcessEnvironmentTests {
    @Test func prependsHomebrewToMinimalLaunchdPath() {
        let result = SubProcess.augmentedPath(
            inherited: "/usr/bin:/bin:/usr/sbin:/sbin",
            additions: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        #expect(result == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func dropsAdditionsAlreadyPresentKeepingTheirPosition() {
        let result = SubProcess.augmentedPath(
            inherited: "/usr/bin:/usr/local/bin:/bin",
            additions: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        // `/usr/local/bin` is already present, so only `/opt/homebrew/bin` is prepended.
        #expect(result == "/opt/homebrew/bin:/usr/bin:/usr/local/bin:/bin")
    }

    @Test func nilInheritedFallsBackToBaseSystemDirs() {
        let result = SubProcess.augmentedPath(
            inherited: nil,
            additions: ["/opt/homebrew/bin"]
        )
        #expect(result == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func emptyInheritedYieldsOnlyAdditions() {
        let result = SubProcess.augmentedPath(
            inherited: "",
            additions: ["/opt/homebrew/bin"]
        )
        // An empty string splits to no entries, but nil's base default only applies to nil; an
        // explicit empty string means "no inherited entries", so the result is the additions alone.
        #expect(result == "/opt/homebrew/bin")
    }
}
