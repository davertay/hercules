import Foundation
import Testing

@testable import Execute

/// A wall-clock instant in a named IANA zone, built via a gregorian calendar so the expected reset and
/// the reference `now` are expressed the same way the parser computes them.
private func at(_ zone: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("RateLimitReset")
struct RateLimitResetTests {

    struct ParseCase: Sendable {
        let name: String
        let message: String
        let now: Date
        let expected: Date
    }

    @Test("Maps a bare-time reset to the next future instant", arguments: [
        // The observed message, with minutes, when the time is still ahead today.
        ParseCase(
            name: "with minutes, same day",
            message: "You've hit your session limit · resets 7:10pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 7, 13, 14, 0),
            expected: at("America/Los_Angeles", 2026, 7, 13, 19, 10)
        ),
        // The observed 12:40am message, hit in the evening → rolls past midnight into the next day.
        ParseCase(
            name: "12:40am crosses midnight",
            message: "You've hit your session limit · resets 12:40am (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 7, 13, 20, 0),
            expected: at("America/Los_Angeles", 2026, 7, 14, 0, 40)
        ),
        // The observed no-minutes form.
        ParseCase(
            name: "no minutes (1pm), same day",
            message: "You've hit your session limit · resets 1pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 7, 13, 8, 0),
            expected: at("America/Los_Angeles", 2026, 7, 13, 13, 0)
        ),
        // Day-rollover: the stated time already passed today, so the next occurrence is tomorrow.
        ParseCase(
            name: "already passed today rolls to tomorrow",
            message: "You've hit your session limit · resets 7:10pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 7, 13, 20, 0),
            expected: at("America/Los_Angeles", 2026, 7, 14, 19, 10)
        ),
        // 12pm/12am boundary handling, and a second timezone to prove the zone is honoured.
        ParseCase(
            name: "12pm noon in New York",
            message: "You've hit your session limit · resets 12pm (America/New_York)",
            now: at("America/New_York", 2026, 7, 13, 9, 0),
            expected: at("America/New_York", 2026, 7, 13, 12, 0)
        ),
    ])
    func mapsToNextReset(_ testCase: ParseCase) {
        #expect(RateLimitReset.parse(testCase.message, now: testCase.now) == testCase.expected, "\(testCase.name)")
    }

    /// The dated shape, which the Harness prints once a reset is more than a day out — the weekly
    /// limit's ordinary case, and the one that used to halt the run as unreadable.
    @Test("Maps a dated reset to the instant it names", arguments: [
        // The observed weekly-limit message, verbatim: `at` separator, no minutes, the following day.
        ParseCase(
            name: "weekly limit, `at` separator",
            message: "You've hit your weekly limit · resets Sep 6 at 3pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 9, 5, 7, 54),
            expected: at("America/Los_Angeles", 2026, 9, 6, 15, 0)
        ),
        // A newer ICU renders the same instant with a comma where the older one puts `at`.
        ParseCase(
            name: "comma separator",
            message: "You've hit your weekly limit · resets Sep 8, 3:30pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 9, 5, 7, 54),
            expected: at("America/Los_Angeles", 2026, 9, 8, 15, 30)
        ),
        // A reset in a later year prints the year, so it is read rather than inferred.
        ParseCase(
            name: "next year carries its year",
            message: "You've hit your weekly limit · resets Jan 8, 2027, 2pm (America/Los_Angeles)",
            now: at("America/Los_Angeles", 2026, 12, 30, 9, 0),
            expected: at("America/Los_Angeles", 2027, 1, 8, 14, 0)
        ),
        // Six days out is what a weekly limit routinely looks like, and it must not be folded into the
        // next-24-hours window the bare-time shape lives in.
        ParseCase(
            name: "a full week out stays a week out",
            message: "You've hit your weekly limit · resets Sep 12 at 9am (America/New_York)",
            now: at("America/New_York", 2026, 9, 6, 11, 0),
            expected: at("America/New_York", 2026, 9, 12, 9, 0)
        ),
    ])
    func mapsDatedResets(_ testCase: ParseCase) {
        #expect(RateLimitReset.parse(testCase.message, now: testCase.now) == testCase.expected, "\(testCase.name)")
    }

    /// Every limit the Harness can name reads the same way: the notice is recognised by the phrasing
    /// they share, not by the limit's own name, so one added later still parses.
    @Test("Reads every limit's name", arguments: [
        "session limit", "weekly limit", "Opus limit", "Sonnet limit", "Fable limit",
        "usage credit limit", "some limit invented later",
    ])
    func readsEveryLimitName(_ limit: String) {
        let message = "You've hit your \(limit) · resets 7:10pm (America/Los_Angeles)"

        #expect(
            RateLimitReset.parse(message, now: at("America/Los_Angeles", 2026, 7, 13, 14, 0))
                == at("America/Los_Angeles", 2026, 7, 13, 19, 10)
        )
    }

    /// The trailing clause the Harness appends when it managed to save the Turn's progress sits after
    /// the timezone, so the clause must be found mid-message rather than at the end of one.
    @Test func readsAResetFollowedByTheProgressSavedSuffix() {
        let message = "You've hit your weekly limit · resets Sep 6 at 3pm (America/Los_Angeles) · progress saved"

        #expect(
            RateLimitReset.parse(message, now: at("America/Los_Angeles", 2026, 9, 5, 7, 54))
                == at("America/Los_Angeles", 2026, 9, 6, 15, 0)
        )
    }

    @Test("Returns nil for text it cannot confidently parse", arguments: [
        // Ordinary completion text — not a limit notice at all.
        "Done. Implemented the parser and added its tests.",
        // Limit notice, but an unrecognized IANA timezone.
        "You've hit your session limit · resets 7:10pm (Mars/Olympus_Mons)",
        // Limit notice, but the time is unparseable prose.
        "You've hit your session limit · resets later tonight (America/Los_Angeles)",
        // A malformed clock hour outside 1...12.
        "You've hit your session limit · resets 25pm (America/Los_Angeles)",
        // Well-formed reset clause but no limit phrasing — must not be mistaken for a limit.
        "The build resets 7:10pm (America/Los_Angeles) each night.",
        // Limit notice missing the timezone entirely.
        "You've hit your session limit · resets 7:10pm",
        // A weekday is not a date the Harness prints, and must not be read as one.
        "You've hit your weekly limit · resets Monday at 3pm (America/Los_Angeles)",
        // A month name that isn't one.
        "You've hit your weekly limit · resets Sap 6 at 3pm (America/Los_Angeles)",
        // A day that doesn't exist in that month — the calendar rejects it rather than rolling over.
        "You've hit your weekly limit · resets Sep 31 at 3pm (America/Los_Angeles)",
    ])
    func returnsNilForUnparseable(_ message: String) {
        #expect(RateLimitReset.parse(message, now: at("America/Los_Angeles", 2026, 7, 13, 14, 0)) == nil)
    }

    /// A dated reset already in the past is not "resume immediately": the caller re-runs the Issue as
    /// soon as the wait returns, so a misread date would spin the run against a live limit.
    @Test func returnsNilForADatedResetInThePast() {
        let message = "You've hit your weekly limit · resets Sep 6 at 3pm (America/Los_Angeles)"

        #expect(RateLimitReset.parse(message, now: at("America/Los_Angeles", 2026, 9, 6, 18, 44)) == nil)
    }
}
