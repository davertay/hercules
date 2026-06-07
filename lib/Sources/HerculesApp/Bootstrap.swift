import Design
import Dependencies
import Foundation

/// Registers app-wide dependencies that can only be resolved from the app target — notably the
/// bundled grill-me Skill markdown the Design Phase injects into its Session. Call once at launch,
/// before any window is shown.
public func bootstrapHercules() {
    prepareDependencies {
        $0.designSkillFile = Bundle.module.url(
            forResource: "grill-me",
            withExtension: "md",
            subdirectory: "Resources/grill-me"
        )
    }
}
