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
    now: Date,
    timeZone: TimeZone = .current
) throws -> String {
    let window = try DateWindow.window(
        from: from, to: to, now: now, timeZone: timeZone,
        defaultFromDays: -30, defaultSpanDays: 60
    )
    let inWindow = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    let examined = inWindow.count

    // Empty query degenerates to "everything in window" (substring "" matches
    // nothing under contains, which would be a surprising no-op).
    let matches = query.isEmpty ? inWindow : inWindow.filter { matchesQuery($0, query, scope) }
    let total = matches.count
    let shown: [EventInfo] = countOnly ? [] : Array(matches.prefix(Swift.max(0, max)))

    if json {
        let summary = SearchSummary(summary: .init(examined: examined, shown: shown.count, total: total))
        return Output.ndjson(shown) + Output.jsonLine(summary)
    }

    if countOnly {
        return "total: \(total)\nexamined: \(examined)\n"
    }

    let multiCalendar = Set(shown.map(\.calendar)).count > 1
    // Columns: when · [calendar] · title · id (human bits first, long id last).
    let rows = shown.map { ev -> [String] in
        let when = Output.when(ev, timeZone: timeZone)
        let title = Output.sanitize(ev.title)
        return multiCalendar ? [when, Output.sanitize(ev.calendar), title, ev.id] : [when, title, ev.id]
    }
    var out = Output.tsv(rows)
    if total > shown.count {
        out += "(showing \(shown.count) of \(total) — narrow filters if too many)\n"
    }
    return out
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
