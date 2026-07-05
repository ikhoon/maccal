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
    color: Bool = false,
    aligned: Bool = false,
    dateStyle: Output.DateStyle = .iso,
    long: Bool = false,
    hideCancelled: Bool = false,
    hiddenCalendars: [String] = [],
    showAll: Bool = false,
    now: Date,
    timeZone: TimeZone = .current
) throws -> String {
    let window = try DateWindow.window(
        from: from, to: to, now: now, timeZone: timeZone,
        defaultFromDays: 0, defaultSpanDays: 7
    )
    var all = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    // Hide-list: drop events from hidden calendars unless `--all`, or unless the
    // user named calendars explicitly (an explicit --calendar means "exactly these").
    if !showAll, calendars.isEmpty, !hiddenCalendars.isEmpty {
        all = all.filter { !$0.matchesCalendar(hiddenCalendars) }
    }
    let events = hideCancelled ? all.filter { $0.status != "canceled" } : all
    let shown = Array(events.prefix(Swift.max(0, max)))

    if json {
        return Output.eventsNDJSON(shown) // no _summary for agenda, matching macmail triage
    }

    // Truncation notice goes to stderr so stdout stays clean, parseable rows.
    if events.count > shown.count {
        Output.warn("showing \(shown.count) of \(events.count) — narrow filters or raise --max")
    }
    // The calendar column only earns its width when results span >1 calendar.
    let multiCalendar = Set(shown.map(\.calendar)).count > 1
    // Calendar colors for the leading marker dot (color mode only) — ties each
    // row visually to `calendars`, so the calendar's own color is the one accent.
    let colorByCal = color ? Dictionary(store.calendars().map { ($0.calendarIdentifier, $0.color) }, uniquingKeysWith: { a, _ in a }) : [:]
    // Columns: [●] · when · [calendar] · id — the id is a short git-style code
    // (full via --long / --json), un-dimmed so it stays legible and copyable.
    let rows = shown.map { ev -> [String] in
        let when = Output.when(ev, style: dateStyle, timeZone: timeZone, now: now)   // no cyan: the dot is the accent
        let title = Output.sanitize(ev.title)
        // Recurring rows carry an occurrence handle (id@epoch) so edit/rm target one.
        let handle = ev.recurring ? Output.occurrenceHandle(id: ev.id, start: ev.start) : ev.id
        let idStr = long ? handle : Output.shortId(handle)
        var row = multiCalendar
            ? [when, Output.paint(Output.sanitize(ev.calendar), .dim, enabled: color), title, idStr]
            : [when, title, idStr]
        if color { row.insert(Output.colorDot(colorByCal[ev.calendarId] ?? ""), at: 0) }
        return row
    }
    return Output.table(rows, aligned: aligned)
}
