import Foundation

/// Parses the harness's session-limit final answer into the instant its limit resets.
///
/// When the executor hits the account's session/credit limit, the failing turn carries a stable
/// final-answer string of the form
/// `You've hit your session limit · resets 7:10pm (America/Los_Angeles)` — a wall-clock time (minutes
/// optional) in a named IANA timezone. Auto-resume (#160) needs the absolute `Date` that time next
/// occurs so it can sleep until then.
///
/// This is deliberately strict and fail-safe: it never guesses. Anything it can't confidently parse —
/// non session-limit text, an unrecognized timezone, a malformed time — yields `nil`, so callers fall
/// back to today's manual-retry behaviour rather than a guessed backoff.
public enum SessionLimitReset {
    /// The next future instant `message`'s stated reset time occurs, relative to `now`, or `nil` when
    /// `message` is not a parseable session-limit message.
    ///
    /// Returns the **next** occurrence: if the stated wall-clock time has already passed today in the
    /// named timezone it rolls to the following day, so the result is always in `(now, now + 24h]`.
    public static func parse(_ message: String, now: Date) -> Date? {
        // The `resets <hour>[:<minute>]<am|pm> (<IANA timezone>)` clause. Case-insensitive; lenient on the
        // surrounding punctuation (the leading `·`) and on whitespace before the parenthesised zone.
        let clause = /\bresets\s+(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<meridiem>[ap]m)\s*\((?<zone>[^)]+)\)/.ignoresCase()

        // Guard the message really is a session-limit notice, not merely any text mentioning "resets".
        guard message.range(of: "session limit", options: .caseInsensitive) != nil,
              let match = message.firstMatch(of: clause),
              let hour = Int(match.output.hour),
              let timeZone = TimeZone(identifier: String(match.output.zone).trimmingCharacters(in: .whitespaces))
        else { return nil }

        let minute = match.output.minute.flatMap { Int($0) } ?? 0
        guard let hour24 = hour24(hour: hour, meridiem: match.output.meridiem) else { return nil }
        guard (0...59).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Anchor to today's date in the target zone, then place the stated wall-clock time on it.
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour24
        components.minute = minute
        components.second = 0
        components.nanosecond = 0
        guard let today = calendar.date(from: components) else { return nil }

        // Already past today → the reset is tomorrow's occurrence (covers the observed midnight-crossing
        // waits). Same wall-clock time, so `byAdding: .day` (which preserves it across any DST shift).
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// Converts a validated 12-hour clock reading to its 24-hour hour, or `nil` when the hour is out of
    /// the 1...12 range a meridiem time can name.
    private static func hour24(hour: Int, meridiem: Substring) -> Int? {
        guard (1...12).contains(hour) else { return nil }
        let isPM = meridiem.lowercased() == "pm"
        if isPM { return hour == 12 ? 12 : hour + 12 }
        return hour == 12 ? 0 : hour
    }
}
