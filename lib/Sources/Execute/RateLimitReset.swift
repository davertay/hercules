import Foundation

/// Parses the Harness's rate-limit final answer into the instant that limit resets.
///
/// A Turn cut off by one of the account's rate limits carries a final answer built as
/// `You've hit your <limit> · resets <when> (<IANA timezone>)`. The limit is the session (5-hour) one,
/// the weekly one, a per-model one, or the usage-credit one; they differ only in the name they print,
/// so all of them are read here. Auto-resume needs the absolute `Date` to sleep until.
///
/// `<when>` has two shapes, chosen by how far off the reset is rather than by which limit was hit:
///
/// - **Within a day**, a bare wall-clock time — `3pm`, `10:30pm`. The date would be today's or
///   tomorrow's, so it is left off and recovered here as the next occurrence.
/// - **Further out**, the date leads — `Sep 6 at 3pm`, `Sep 8, 3:30pm`, `Jan 8, 2027, 2pm`. The
///   separator between date and time varies with the Harness build's ICU, so both are read. The year
///   appears only when it isn't the current one, which is what makes inferring it safe.
///
/// The weekly limit is the one that routinely resets days out, so it is the one that surfaces the
/// dated shape — but nothing here is keyed to a particular limit, and a session limit far enough
/// away would print a date too.
///
/// Deliberately strict and fail-safe: it never guesses. Anything it can't confidently parse — text
/// that isn't a limit notice, an unrecognized timezone, a malformed time, a dated reset that resolves
/// to the past — yields `nil`, so callers halt for a manual retry rather than sleeping on a guess.
public enum RateLimitReset {
    /// The instant `message`'s stated reset occurs, or `nil` when `message` is not a parseable
    /// rate-limit notice.
    ///
    /// The result is always in the future. A dated reset is honoured verbatim; one that resolves to
    /// the past is treated as unparseable rather than as "resume immediately", because the caller
    /// re-runs the Issue the moment this returns — a reset misread as long past would spin the run
    /// against a limit that is still in force.
    public static func parse(_ message: String, now: Date) -> Date? {
        // Lenient on the surrounding punctuation (the leading `·`) and on whitespace before the
        // parenthesised zone. The date is one optional group: wholly absent for the bare-time shape.
        let clause = #/
            \bresets \s+
            (?:                                    # the dated shape's leading date
                (?<month> [a-z]{3}) \s+ (?<day> \d{1,2})
                (?: , \s* (?<year> \d{4}) )?       # printed only when it isn't the current year
                (?: , | \s+ at ) \s+               # the separator varies with the Harness build's ICU
            )?
            (?<hour> \d{1,2}) (?: : (?<minute> \d{2}) )? \s* (?<meridiem> [ap]m)
            \s* \( (?<zone> [^)]+ ) \)
        /#.ignoresCase()

        // Guard the message really is a limit notice, not merely any text mentioning "resets". Every
        // one of them is built as "You've hit your <limit>", so the limit's own name is not matched on
        // — a name added later would otherwise silently stop being read.
        guard message.range(of: "hit your", options: .caseInsensitive) != nil,
              let match = message.firstMatch(of: clause),
              let hour = Int(match.output.hour),
              let timeZone = TimeZone(identifier: String(match.output.zone).trimmingCharacters(in: .whitespaces))
        else { return nil }

        let minute = match.output.minute.flatMap { Int($0) } ?? 0
        guard let hour24 = hour24(hour: hour, meridiem: match.output.meridiem) else { return nil }
        guard (0...59).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var components = DateComponents()
        components.hour = hour24
        components.minute = minute
        components.second = 0
        components.nanosecond = 0

        guard let month = match.output.month, let day = match.output.day else {
            return nextOccurrence(of: components, calendar: calendar, now: now)
        }

        guard let monthNumber = monthNumber(month), let dayNumber = Int(day) else { return nil }
        components.month = monthNumber
        components.day = dayNumber
        // The year is printed only when it differs from the current one, so its absence *means* the
        // current year — read in the reset's own zone, where the Harness read it.
        components.year = match.output.year.flatMap { Int($0) } ?? calendar.component(.year, from: now)

        guard let resetAt = calendar.date(from: components), resetAt > now else { return nil }
        // `date(from:)` is lenient about a day its month doesn't have, rolling Sep 31 into Oct 1. The
        // Harness prints a real date or none, so one that doesn't survive the round trip was misread
        // here rather than written there — and rolling it forward would be exactly the guess this
        // refuses to make. A wall-clock time inside a spring-forward gap shifts only its hour, so it
        // still round-trips and is still honoured.
        let rendered = calendar.dateComponents([.year, .month, .day], from: resetAt)
        guard rendered.year == components.year,
              rendered.month == components.month,
              rendered.day == components.day
        else { return nil }
        return resetAt
    }

    /// The next future instant carrying `components`' wall-clock time. If it has already passed today
    /// the reset is tomorrow's occurrence — the observed midnight-crossing wait — so the result is
    /// always in `(now, now + 24h]`, which is exactly the window the Harness omits the date for.
    private static func nextOccurrence(
        of components: DateComponents, calendar: Calendar, now: Date
    ) -> Date? {
        var components = components
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        components.year = today.year
        components.month = today.month
        components.day = today.day

        guard let todayAtTime = calendar.date(from: components) else { return nil }
        // Same wall-clock time tomorrow, so `byAdding: .day` (which preserves it across any DST shift).
        return todayAtTime > now ? todayAtTime : calendar.date(byAdding: .day, value: 1, to: todayAtTime)
    }

    /// The month number for an en-US three-letter abbreviation, which is the only form the Harness
    /// prints (its formatter asks for a short month, and en-US short months are all three letters).
    private static func monthNumber(_ abbreviation: Substring) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: abbreviation.lowercased()).map { $0 + 1 }
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
