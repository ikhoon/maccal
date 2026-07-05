// Commands/Calendars.swift — `maccal calendars`.
//
// Lists the calendars maccal can see, for use as `--calendar` selectors. The
// macmail `accounts` analog. Pure logic over a CalendarStore so it's testable
// against FakeCalendarStore; the ArgumentParser struct in main.swift parses
// flags and calls this.

import Foundation

public func runCalendars(
    store: CalendarStore,
    json: Bool,
    writableOnly: Bool = false,
    sourceFilter: String? = nil,
    hiddenCalendars: [String] = [],
    showAll: Bool = false,
    color: Bool = false,
    aligned: Bool = false
) -> String {
    var cals = store.calendars()
    if writableOnly {
        cals = cals.filter { $0.writable }
    }
    if let sf = sourceFilter, !sf.isEmpty {
        cals = cals.filter { $0.source.localizedCaseInsensitiveContains(sf) }
    }
    // Hide-list (config.hiddenCalendars): drop calendars matched by title or
    // identifier unless `--all`. Applies to both text and JSON so scripts see the
    // same visible set the human does. Routed through Config.isHidden — the one
    // matcher — so folding matches agenda/search/free (matchesCalendar) exactly.
    if !showAll, !hiddenCalendars.isEmpty {
        let hide = Config(hiddenCalendars: hiddenCalendars)
        cals = cals.filter { !hide.isHidden(title: $0.title, identifier: $0.calendarIdentifier) }
    }
    // Group by source, then title (case-insensitive) — the order you scan when
    // picking a calendar.
    cals.sort { a, b in
        let bySource = a.source.localizedCaseInsensitiveCompare(b.source)
        if bySource != .orderedSame { return bySource == .orderedAscending }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    if json {
        return Output.ndjson(cals)
    }
    // Text mode shows the columns useful for selecting a calendar; JSON carries
    // everything (identifier, sourceType, color). Free-text cells (title, source)
    // are sanitized so a tab/newline in a calendar or account name can't split or
    // widen a row. Color, when on, is a leading dot in the calendar's own color;
    // the hex lives only in --json.
    let rows = cals.map { c -> [String] in
        let rw = c.writable
            ? Output.paint("rw", .green, enabled: color)
            : Output.paint("ro", .yellow, enabled: color)
        var row = [
            Output.sanitize(c.title),
            Output.paint(Output.sanitize(c.source), .dim, enabled: color),
            Output.paint(Output.sanitize(c.type), .dim, enabled: color),
            rw,
        ]
        if color { row.insert(Output.colorDot(c.color), at: 0) }
        return row
    }
    return Output.table(rows, aligned: aligned)
}
