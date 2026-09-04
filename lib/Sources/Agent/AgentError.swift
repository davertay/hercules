import Foundation
import Store

public enum AgentError: Error, Sendable {
    case harnessNotFound(triedPath: URL)
    /// `reason` is the failure class the Harness reported for itself (`rate_limit`, `overloaded`, …),
    /// or `nil` when it reported none — the case for every Turn whose Harness didn't run the hook.
    case harnessFailed(exitCode: Int32, stderrTail: String, reason: String?)
    case harnessCrashed(signal: Int32, stderrTail: String)
    case harnessIOFailed(underlying: any Error)
    case sessionNotFound(id: Session.ID)
    case malformedStream(line: String, underlying: any Error)
    case storeWriteFailed(underlying: any Error)
    case inputUnreadable(URL, underlying: any Error)
    case sessionBusy(id: Session.ID)
    case mcpConfigDirectoryMissing
    case cancelled
}

extension AgentError {
    /// Whether the Harness reported *for itself* that it gave the Turn up to the account's rate limit —
    /// the one failure class worth waiting out rather than halting on.
    ///
    /// `false` for a failure that reported no reason at all, which is every Turn whose Harness didn't
    /// run the hook: an unreported rate limit is indistinguishable from any other failure and is
    /// treated as one. It is deliberately not inferred from the wording of `stderrTail` — prose that
    /// mentions a limit is not the Harness saying it hit one.
    public var isReportedRateLimit: Bool {
        guard case .harnessFailed(_, _, let reason) = self else { return false }
        return reason == Self.rateLimitReason
    }

    /// The reason the Harness reports when the account's rate limit ended the Turn. Its siblings
    /// (`overloaded`, and whatever the taxonomy grows) get no constant here on purpose: none of them
    /// changes what a caller does, and naming them would imply otherwise.
    private static let rateLimitReason = "rate_limit"
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .harnessNotFound(triedPath: let triedPath):
            "Harness not found at \(triedPath.relativePath)"
        case .harnessFailed(exitCode: let exitCode, stderrTail: let stderrTail, reason: let reason):
            // The reason is parenthesised in rather than replacing anything: it names the class of
            // failure, while the detail carries the Harness's own wording, and a reader wants both.
            "Harness failed code=\(exitCode)\(reason.map { " (\($0))" } ?? ""): \(stderrTail)"
        case .harnessCrashed(signal: let signal, stderrTail: let stderrTail):
            "Harness crashed signal=\(signal): \(stderrTail)"
        case .harnessIOFailed(underlying: let underlying):
            "Harness I/O failed caused by: \(underlying.localizedDescription)"
        case .sessionNotFound(id: let id):
            "Session not found \(id)"
        case .malformedStream(line: let line, underlying: let underlying):
            "Malformed stream at '\(line)' caused by: \(underlying.localizedDescription)"
        case .storeWriteFailed(underlying: let underlying):
            "Store write failed caused by: \(underlying.localizedDescription)"
        case .inputUnreadable(_, underlying: let underlying):
            "Input unreadable caused by: \(underlying.localizedDescription)"
        case .sessionBusy(id: let id):
            "Session busy \(id)"
        case .mcpConfigDirectoryMissing:
            "MCP servers were configured but no Session data directory was provided to write --mcp-config into"
        case .cancelled:
            "Cancelled"
        }
    }
}
