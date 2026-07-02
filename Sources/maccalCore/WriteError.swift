// WriteError.swift — error types for the write path.
//
// MaccalError unifies every domain error maccal reports the same way:
// "maccal: <description>" on stderr with exit 1. The command layer catches
// MaccalError once instead of each concrete type. WriteValidationError is the
// pure pre-save validation (run* layer, fully testable); WriteError is what the
// store throws when talking to EventKit.

import Foundation

/// A domain error reported as `maccal: <description>` (stderr, exit 1).
public protocol MaccalError: Error, CustomStringConvertible {}

// Existing parse errors join the family so the command layer has one catch.
extension DateWindow.ParseError: MaccalError {}
extension DateTime.ParseError: MaccalError {}

/// Pure pre-save validation failures — no half-built event is ever persisted.
public enum WriteValidationError: MaccalError, Equatable {
    case emptyTitle
    case missingEnd                       // timed add: neither --end nor --duration
    case endAndDurationConflict           // both --end and --duration
    case endNotAfterStart
    case allDayWithTime                   // all-day event with a clock time / sub-day span
    case invalidURL(String)
    case invalidAvailability(String)
    case invalidTimeZone(String)
    case recurringRequiresAllOccurrences  // a recurring event needs --all-occurrences
    case noChanges
    case sameSourceTarget                 // sync --from and --to resolve to the same calendar

    public var description: String {
        switch self {
        case .emptyTitle: return "title must not be empty"
        case .missingEnd: return "a timed event needs --end or --duration"
        case .endAndDurationConflict: return "--end and --duration are mutually exclusive"
        case .endNotAfterStart: return "end must be after start"
        case .allDayWithTime: return "an all-day event needs date-only, whole-day --start/--end (no clock time)"
        case .invalidURL(let u): return "invalid url: \(u)"
        case .invalidAvailability(let a): return "invalid availability '\(a)' (use busy|free|tentative|unavailable)"
        case .invalidTimeZone(let z): return "invalid time zone '\(z)'"
        case .recurringRequiresAllOccurrences:
            return "this is a recurring event — re-run with --all-occurrences to change the whole series (per-occurrence edits are not yet supported)"
        case .noChanges: return "no changes given"
        case .sameSourceTarget: return "--from and --to must be different calendars"
        }
    }
}

/// Failures from the store while resolving calendars or saving/removing.
public enum WriteError: MaccalError, Equatable {
    case notFound(String)           // event id
    case notWritable                // target calendar is read-only
    case calendarNotFound(String)   // selector matched nothing
    case ambiguousCalendar(String)  // selector matched >1
    case noWritableCalendar         // no default new-event calendar
    case storeFailure(String)       // EventKit NSError

    public var description: String {
        switch self {
        case .notFound(let id): return "event \(id) not found"
        case .notWritable: return "the event's calendar is read-only"
        case .calendarNotFound(let s): return "no calendar matches '\(s)'"
        case .ambiguousCalendar(let s): return "'\(s)' matches more than one calendar — be more specific"
        case .noWritableCalendar: return "no default calendar for new events is configured"
        case .storeFailure(let m): return "calendar store error: \(m)"
        }
    }
}
