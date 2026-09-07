import Foundation
import SnapshotTesting
import SnapshotTestingCustomDump
import Testing

@testable import Agent

@Suite("SubProcess — the child's environment")
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

    // MARK: - The launched environment

    /// The whole of what the child is launched with over its inherited environment. Snapshotted so an
    /// addition here is a deliberate one: everything in this dictionary is a measured behaviour of the
    /// Harness, and a variable that does nothing is worse than no variable at all.
    @Test func theChildIsLaunchedWithThePathAndTheIdleTimeoutAndNothingElse() {
        let overrides = SubProcess.environmentOverrides(inherited: "/usr/bin:/bin")

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: overrides, as: .customDump)
        }
    }

    /// A blocking `ask_user` call is silent for as long as the user takes to answer, and the Harness's
    /// own idle timer aborts a silent tool call at just over thirty minutes. Disabling it is what lets a
    /// question outlive the user making a cup of tea.
    @Test func theMCPToolIdleTimeoutIsDisabled() {
        let overrides = SubProcess.environmentOverrides(inherited: "/usr/bin:/bin")

        #expect(overrides["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"] == "0")
    }

    /// The `PATH` augmentation is untouched by the addition above — it is still the augmented one, and
    /// the launched environment is still `.inherit` plus these two, not a replacement for it.
    @Test func thePathOverrideIsStillTheAugmentedPath() {
        let overrides = SubProcess.environmentOverrides(inherited: "/usr/bin:/bin")

        #expect(overrides["PATH"] == SubProcess.augmentedPath(inherited: "/usr/bin:/bin"))
        #expect(overrides["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}
