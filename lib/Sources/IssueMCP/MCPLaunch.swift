// Shared CLI argument parsing for the module's `@main` re-exec launch branches (`IssueMCPLaunch`,
// `ArtifactMCPLaunch`), whose flag operands are fixed by the app and invisible to the model.

/// Returns the operand following `flag`, or `nil` when the flag is absent or is the final argument.
func mcpLaunchValue(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}
