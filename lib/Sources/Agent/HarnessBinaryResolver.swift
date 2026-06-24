import Foundation

/// Resolves which harness binary a Session should run.
///
/// Resolution order:
/// 1. A non-empty configured path wins.
/// 2. Otherwise scan `PATH` for `claude` via the injected lookup.
/// 3. Otherwise return an unresolved placeholder that fails the caller's executability guard.
///
/// Pure and environment-free: callers inject the `PATH` lookup, so the resolver is unit-testable
/// without touching the process environment or filesystem.
enum HarnessBinaryResolver {
    /// Returned when neither a configured path nor a `PATH` match resolves. A bare name is never an
    /// executable file, so the caller's executability guard throws `AgentError.harnessNotFound`.
    static let unresolved = URL(fileURLWithPath: "claude")

    /// - Parameters:
    ///   - configuredPath: `AppConfig.agentExecutablePath`. Whitespace-only is treated as empty.
    ///   - lookup: Scans `PATH` for `claude`, returning its URL or `nil` when absent.
    static func resolve(configuredPath: String?, lookup: () -> URL?) -> URL {
        if let configuredPath,
            !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: configuredPath)
        }
        return lookup() ?? unresolved
    }

    /// The live `PATH` lookup: returns the first directory on `PATH` holding an executable `claude`.
    static func pathLookup(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
