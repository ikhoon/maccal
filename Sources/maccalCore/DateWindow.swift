// DateWindow.swift — pure date/range parsing for event windows.
//
// Resolves the --from/--to forms into local-midnight Dates and a half-open
// DateInterval handed to CalendarStore.events(in:calendars:). Kept pure and
// clock-injectable (now + timeZone are parameters) so maccalCheck tests it with
// a fixed clock, never touching EventKit — the same seam runCalendars uses.
//
// Day math goes through Calendar.date(byAdding:) rather than raw TimeIntervals,
// so windows land on local midnight even across a DST change (a local day is not
// always 86400s). Construction matches Output.localISO/localDate exactly, so day
// boundaries agree with the text rendering.

import Foundation

public enum DateWindow {
    /// Thrown for a syntactically or calendar-impossible bound (e.g. 2026-02-30).
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let input: String
        public init(input: String) { self.input = input }
        public var description: String { "invalid date: \(input)" }
    }

    /// Supported forms (case-insensitive keywords):
    ///   YYYY-MM-DD | today | tomorrow | yesterday | +Nd | -Nd | +Nw | -Nw
    /// Relative forms are resolved against the start of today (not `now`), so
    /// results are stable within a day. Returns a local-midnight Date in `timeZone`.
    public static func parseBound(_ s: String, now: Date, timeZone: TimeZone) throws -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)

        switch trimmed.lowercased() {
        case "today": return today
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: today)!
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: today)!
        default: break
        }

        if let relative = relativeOffset(trimmed, calendar: cal, from: today) { return relative }
        if let explicit = explicitDate(trimmed, calendar: cal) { return explicit }
        throw ParseError(input: s)
    }

    /// Half-open window [start, end) in `timeZone`. When a bound is nil it defaults
    /// to: start = today + `defaultFromDays`; end = start + `defaultSpanDays`. An
    /// empty or reversed range (end <= start) is clamped to a zero-length interval
    /// — zero events, never a crash.
    public static func window(
        from: String?,
        to: String?,
        now: Date,
        timeZone: TimeZone,
        defaultFromDays: Int,
        defaultSpanDays: Int
    ) throws -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)

        let start = try from.map { try parseBound($0, now: now, timeZone: timeZone) }
            ?? cal.date(byAdding: .day, value: defaultFromDays, to: today)!
        let end = try to.map { try parseBound($0, now: now, timeZone: timeZone) }
            ?? cal.date(byAdding: .day, value: defaultSpanDays, to: start)!

        return end <= start ? DateInterval(start: start, end: start) : DateInterval(start: start, end: end)
    }

    // MARK: - Bound parsing

    /// `+Nd` / `-Nd` / `+Nw` / `-Nw` (sign optional, defaults positive) → a date
    /// offset from `base` by whole days/weeks via the calendar (DST-correct).
    private static func relativeOffset(_ s: String, calendar cal: Calendar, from base: Date) -> Date? {
        guard let unit = s.last, unit == "d" || unit == "w" else { return nil }
        var body = String(s.dropLast())
        var sign = 1
        if body.hasPrefix("+") { body.removeFirst() }
        else if body.hasPrefix("-") { sign = -1; body.removeFirst() }
        guard !body.isEmpty, body.allSatisfy(\.isNumber), let n = Int(body) else { return nil }
        let component: Calendar.Component = unit == "d" ? .day : .weekOfYear
        return cal.date(byAdding: component, value: sign * n, to: base)
    }

    /// Strict zero-padded YYYY-MM-DD, rejecting calendar-impossible dates by
    /// requiring the parsed components to round-trip unchanged.
    private static func explicitDate(_ s: String, calendar cal: Calendar) -> Date? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }

        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return cal.startOfDay(for: date)
    }
}
