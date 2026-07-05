// Commands/Search.swift — `maccal search <query>`.
//
// Finds events whose chosen fields contain a query substring within a date
// window — the calendar twin of macmail's search. EventKit has no text
// predicate for events, so we fetch the bounded window via the same
// events(in:calendars:) path and substring-filter the mapped DTOs in pure code.
// SearchCommand in main.swift parses flags, gates access, and calls runSearch.

import Foundation

/// Which fields the query is matched against.
public enum SearchScope: String, CaseIterable, Sendable {
    case title, location, notes, all
}

/// The trailing `{"_summary":{shown,total,examined}}` line for `--json`.
/// `examined` is the number of events scanned in the window; `total` is the full
/// match count (computed before `--max`); `shown` is how many rows were emitted.
struct SearchSummary: Encodable {
    struct Counts: Encodable {
        let examined: Int
        let shown: Int
        let total: Int
    }
    let summary: Counts
    enum CodingKeys: String, CodingKey { case summary = "_summary" }
}

/// - Throws: DateWindow.ParseError on an invalid --from/--to.
public func runSearch(
    store: CalendarStore,
    query: String,
    json: Bool,
    calendars: [String] = [],
    scope: SearchScope = .all,
    from: String? = nil,
    to: String? = nil,
    max: Int = 10,
    countOnly: Bool = false,
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
        defaultFromDays: -30, defaultSpanDays: 60
    )
    var inWindow = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    // Hide-list: same rule as agenda — excluded unless --all or explicit --calendar.
    if !showAll, calendars.isEmpty, !hiddenCalendars.isEmpty {
        inWindow = inWindow.filter { !$0.matchesCalendar(hiddenCalendars) }
    }
    let examined = inWindow.count

    // Empty query degenerates to "everything in window" (substring "" matches
    // nothing under contains, which would be a surprising no-op).
    let matched = query.isEmpty ? inWindow : inWindow.filter { matchesQuery($0, query, scope) }
    let matches = hideCancelled ? matched.filter { $0.status != "canceled" } : matched
    let total = matches.count
    let shown: [EventInfo] = countOnly ? [] : Array(matches.prefix(Swift.max(0, max)))

    if json {
        let summary = SearchSummary(summary: .init(examined: examined, shown: shown.count, total: total))
        return Output.eventsNDJSON(shown) + Output.jsonLine(summary)
    }

    if countOnly {
        return "total: \(total)\nexamined: \(examined)\n"
    }

    if total > shown.count {
        Output.warn("showing \(shown.count) of \(total) — narrow filters or raise --max")
    }
    let multiCalendar = Set(shown.map(\.calendar)).count > 1
    let colorByCal = color ? Dictionary(store.calendars().map { ($0.calendarIdentifier, $0.color) }, uniquingKeysWith: { a, _ in a }) : [:]
    // Columns: [●] · when · [calendar] · id — matching agenda's Ink & Token
    // styling: bold title, default-fg when/calendar, cyan copyable id.
    let rows = shown.map { ev -> [String] in
        let when = Output.when(ev, style: dateStyle, timeZone: timeZone, now: now)
        let title = Output.paint(Output.sanitize(ev.title), .bold, enabled: color)
        let handle = ev.recurring ? Output.occurrenceHandle(id: ev.id, start: ev.start) : ev.id
        let idStr = Output.paint(long ? handle : Output.shortId(handle), .cyan, enabled: color)
        var row = multiCalendar
            ? [when, Output.sanitize(ev.calendar), title, idStr]
            : [when, title, idStr]
        if color { row.insert(Output.colorDot(colorByCal[ev.calendarId] ?? ""), at: 0) }
        return row
    }
    return Output.table(rows, aligned: aligned)
}

/// Case-insensitive substring match over the fields selected by `scope`.
private func matchesQuery(_ e: EventInfo, _ query: String, _ scope: SearchScope) -> Bool {
    func has(_ s: String) -> Bool { s.localizedCaseInsensitiveContains(query) }
    switch scope {
    case .title: return has(e.title)
    case .location: return has(e.location)
    case .notes: return has(e.notes)
    case .all: return has(e.title) || has(e.location) || has(e.notes)
    }
}
