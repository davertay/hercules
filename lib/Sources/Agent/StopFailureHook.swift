import Foundation

/// Hercules's one Claude Code hook: a `StopFailure` handler that reports *why* the Harness gave up on
/// a Turn — `rate_limit`, `overloaded`, whatever else the taxonomy grows — as a value, instead of
/// leaving Hercules to read the class of failure out of the agent's parting prose.
///
/// The hook is registered per Turn through a generated `--settings` file, and it is a shell-form
/// command: those receive the event payload on stdin, so the whole sidecar is a `cat` into a file and
/// nothing has to be shipped alongside the app or resolved on the child's `PATH`. The file it writes
/// is keyed by turn id, so a drop-file an earlier Turn left behind can never be read as this one's.
///
/// Every step degrades to silence. No file, an unreadable one, a payload that isn't an object, no
/// `reason` in it — all read as "the Harness said nothing", which is exactly the state Hercules was in
/// before the hook existed. Nothing here is load-bearing for a Turn that ends normally.
enum StopFailureHook {
    /// The settings payload registering the hook, as the Harness's `--settings <file>` reads it.
    ///
    /// The matcher is a wildcard on purpose. Naming today's reasons (`rate_limit|overloaded|…`) costs
    /// the same to write and hardcodes a taxonomy that is not ours to freeze: a reason added later
    /// would simply stop being reported, silently. Capture everything and switch on it in Swift, where
    /// an unrecognized reason is still a recorded fact.
    ///
    /// Keys are sorted so the rendered file is deterministic, and slashes are left alone so the command
    /// reads as the shell line it is — `\/` parses back to the same path, but nobody debugging a hook
    /// wants to read a path spelled that way.
    static func settingsJSON(dropFile: URL) throws -> Data {
        let root: [String: Any] = [
            "hooks": [
                "StopFailure": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "cat > \(shellQuoted(dropFile.path))"]
                        ],
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The reason the Harness reported for stopping this Turn — the payload's `reason` — or `nil` when
    /// it reported nothing, which is every Turn that ends without the hook firing.
    static func reportedReason(dropFile: URL) -> String? {
        guard
            let data = try? Data(contentsOf: dropFile),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reason = payload["reason"] as? String,
            !reason.isEmpty
        else { return nil }
        return reason
    }

    /// Wraps `path` in single quotes for the hook command's shell body. The Session's data directory
    /// can't hold a quote today, but a path interpolated into a shell command is one character away
    /// from being something else entirely, so it is quoted where it is built rather than trusted.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
