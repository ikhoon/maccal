// Commands/Agenda.swift — `maccal agenda`.
//
// Lists events whose [start, end) overlaps a date window, soonest first — the
// calendar twin of macmail's `triage`. Pure logic over a CalendarStore so it's
// testable against FakeCalendarStore with an injected clock; AgendaCommand in
// main.swift parses flags, gates Calendar access, and calls this.

import Foundation

/// - Parameters:
///   - max: maximum rows shown; the trailer still reports the true total.
///   - now/timeZone: injected so tests are deterministic.
/// - Throws: DateWindow.ParseError on an invalid --from/--to.
public func runAgenda(
    store: CalendarStore,
    json: Bool,
    calendars: [String] = [],
    from: String? = nil,
    to: String? = nil,
    max: Int = 20,
    now: Date,
    timeZone: TimeZone = .current
) throws -> String {
    let window = try DateWindow.window(
        from: from, to: to, now: now, timeZone: timeZone,
        defaultFromDays: 0, defaultSpanDays: 7
    )
    let events = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    let shown = Array(events.prefix(Swift.max(0, max)))

    if json {
        return Output.ndjson(shown) // no _summary for agenda, matching macmail triage
    }

    // The calendar column only earns its width when results span >1 calendar.
    let multiCalendar = Set(shown.map(\.calendar)).count > 1
    // Columns: when · [calendar] · title · id — the human-readable bits first,
    // the long id last (use --json for scripting).
    let rows = shown.map { ev -> [String] in
        let when = Output.when(ev, timeZone: timeZone)
        let title = Output.sanitize(ev.title)
        return multiCalendar ? [when, Output.sanitize(ev.calendar), title, ev.id] : [when, title, ev.id]
    }
    var out = Output.tsv(rows)
    if events.count > shown.count {
        out += "(showing \(shown.count) of \(events.count) — narrow filters if too many)\n"
    }
    return out
}
