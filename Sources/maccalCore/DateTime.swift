// DateTime.swift — pure datetime + duration parsing for event writes.
//
// Extends DateWindow with an optional clock time on top of its date forms, plus
// a duration grammar. Pure and clock/timeZone-injectable so maccalCheck tests it
// with a fixed clock, never touching EventKit. The date part is delegated to
// DateWindow.parseBound so the read-window and write parsers can't drift; all
// day/week/hour/minute math goes through Calendar.date(byAdding:) so DST gaps
// resolve like the OS.

import Foundation

public enum DateTime {
    /// Thrown for a malformed datetime or duration. Same spirit as
    /// DateWindow.ParseError; the command layer prints "maccal: <description>".
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public enum Kind: Equatable, Sendable { case dateTime, duration }
        public let input: String
        public let kind: Kind
        public init(_ input: String, kind: Kind = .dateTime) {
            self.input = input
            self.kind = kind
        }
        public var description: String {
            switch kind {
            case .dateTime: return "invalid date/time: \(input)"
            case .duration: return "invalid duration: \(input)"
            }
        }
    }

    /// Parse a --start/--end value into an absolute instant. `isDateOnly` is true
    /// for the date-only (all-day candidate) forms, false when a clock time is
    /// present. Supported: every DateWindow.parseBound date form, optionally
    /// followed by a clock time as `…THH:MM[:SS]` or `… HH:MM[:SS]`.
    public static func parse(_ s: String, now: Date, timeZone: TimeZone) throws -> (date: Date, isDateOnly: Bool) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError(s) }

        if let (datePart, timePart) = splitDateTime(trimmed) {
            let day = try parseDate(datePart, original: s, now: now, timeZone: timeZone)
            let (h, m, sec) = try parseClock(timePart, original: s)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            guard let dt = cal.date(byAdding: DateComponents(hour: h, minute: m, second: sec), to: day) else {
                throw ParseError(s)
            }
            return (dt, false)
        }

        return (try parseDate(trimmed, original: s, now: now, timeZone: timeZone), true)
    }

    /// Parse a duration token (single `30m`/`2h`/`1d`/`1w` or strictly
    /// descending compound `1h30m`/`1w2d`) into DateComponents added via the
    /// calendar. Bare integers, internal spaces, repeated/ascending units, and
    /// zero/negative values are rejected.
    public static func parseDuration(_ s: String) throws -> DateComponents {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw ParseError(s, kind: .duration) }

        // Smaller rank = larger unit; units must appear in strictly descending
        // size (each at most once).
        let rank = ["w": 0, "d": 1, "h": 2, "m": 3]
        var comps = DateComponents()
        var digits = ""
        var lastRank = -1
        var sawUnit = false

        for ch in trimmed {
            if ch.isNumber { digits.append(ch); continue }
            guard let r = rank[String(ch)], !digits.isEmpty, let value = Int(digits), value > 0, r > lastRank else {
                throw ParseError(s, kind: .duration)
            }
            lastRank = r
            switch ch {
            case "w": comps.weekOfYear = value
            case "d": comps.day = value
            case "h": comps.hour = value
            default: comps.minute = value
            }
            digits = ""
            sawUnit = true
        }
        // A trailing number with no unit (e.g. "1h30") or no units at all is invalid.
        guard sawUnit, digits.isEmpty else { throw ParseError(s, kind: .duration) }
        return comps
    }

    // MARK: - Internals

    /// Split "<date>T<time>" (ISO) or "<date> <time>" (space); nil if no clock.
    private static func splitDateTime(_ s: String) -> (date: String, time: String)? {
        // ISO-T: a 'T' immediately after a YYYY-MM-DD prefix (offset 10).
        if s.count > 10 {
            let tIdx = s.index(s.startIndex, offsetBy: 10)
            if s[tIdx] == "T" {
                return (String(s[..<tIdx]), String(s[s.index(after: tIdx)...]))
            }
        }
        if let sp = s.firstIndex(of: " ") {
            let date = String(s[..<sp]).trimmingCharacters(in: .whitespaces)
            let time = String(s[s.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            return date.isEmpty || time.isEmpty ? nil : (date, time)
        }
        return nil
    }

    private static func parseDate(_ s: String, original: String, now: Date, timeZone: TimeZone) throws -> Date {
        do { return try DateWindow.parseBound(s, now: now, timeZone: timeZone) }
        catch { throw ParseError(original) }
    }

    /// Strict zero-padded HH:MM[:SS] in 24h, range-validated.
    private static func parseClock(_ s: String, original: String) throws -> (Int, Int, Int) {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1])
        else { throw ParseError(original) }
        let sec = parts.count == 3 ? (Int(parts[2]) ?? -1) : 0
        guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(sec) else { throw ParseError(original) }
        return (h, m, sec)
    }
}
