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
    sourceFilter: String? = nil
) -> String {
    var cals = store.calendars()
    if writableOnly {
        cals = cals.filter { $0.writable }
    }
    if let sf = sourceFilter, !sf.isEmpty {
        cals = cals.filter { $0.source.localizedCaseInsensitiveContains(sf) }
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
    // everything (identifier, sourceType, color).
    let rows = cals.map { c in
        [c.title, c.source, c.type, c.writable ? "rw" : "ro", c.color]
    }
    return Output.tsv(rows)
}
