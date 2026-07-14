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

@Suite("SessionLimitReset")
struct SessionLimitResetTests {

    struct ParseCase: Sendable {
        let name: String
        let message: String
        let now: Date
        let expected: Date
    }

    @Test("Maps a session-limit message to the next future reset instant", arguments: [
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
        #expect(SessionLimitReset.parse(testCase.message, now: testCase.now) == testCase.expected, "\(testCase.name)")
    }

    @Test("Returns nil for text it cannot confidently parse", arguments: [
        // Ordinary completion text — not a session-limit notice at all.
        "Done. Implemented the parser and added its tests.",
        // Session-limit notice, but an unrecognized IANA timezone.
        "You've hit your session limit · resets 7:10pm (Mars/Olympus_Mons)",
        // Session-limit notice, but the time is unparseable prose.
        "You've hit your session limit · resets later tonight (America/Los_Angeles)",
        // A malformed clock hour outside 1...12.
        "You've hit your session limit · resets 25pm (America/Los_Angeles)",
        // Well-formed reset clause but no session-limit phrasing — must not be mistaken for a limit.
        "The build resets 7:10pm (America/Los_Angeles) each night.",
        // Session-limit notice missing the timezone entirely.
        "You've hit your session limit · resets 7:10pm",
    ])
    func returnsNilForUnparseable(_ message: String) {
        #expect(SessionLimitReset.parse(message, now: at("America/Los_Angeles", 2026, 7, 13, 14, 0)) == nil)
    }
}
