import Foundation
import Testing

@testable import Agent

/// The Harness's own account of why it stopped, read as a predicate. Execute's auto-resume is gated on
/// it, so what it answers `false` to matters as much as what it answers `true` to.
@Suite("AgentError.isReportedRateLimit")
struct AgentErrorTests {
    @Test func trueForAReportedRateLimit() {
        let error = AgentError.harnessFailed(exitCode: 1, stderrTail: "", reason: "rate_limit")

        #expect(error.isReportedRateLimit)
    }

    /// The stderr tail here reads as a textbook session limit and is ignored throughout: a reason of
    /// `nil` — the hook didn't fire, or this Harness has no such event — is not a rate limit, and neither
    /// is a reason that merely resembles one. Nothing is normalized, because guessing is how the prose
    /// scraping this replaced went wrong.
    @Test(arguments: [nil, "", "overloaded", "RATE_LIMIT", "rate_limit_exceeded"] as [String?])
    func falseForEveryOtherReportedReason(reason: String?) {
        let error = AgentError.harnessFailed(
            exitCode: 1, stderrTail: "You've hit your session limit · resets 11pm (UTC)", reason: reason
        )

        #expect(error.isReportedRateLimit == false)
    }

    /// A reason rides on the non-zero exit and nowhere else, so every other failure is `false` by shape.
    @Test func falseForFailuresThatCarryNoReasonAtAll() {
        #expect(AgentError.harnessCrashed(signal: 9, stderrTail: "rate_limit").isReportedRateLimit == false)
        #expect(AgentError.cancelled.isReportedRateLimit == false)
    }
}
