// Commands/Free.swift — `maccal free`: open slots within working hours.
//
// Finds gaps of at least `minDuration` inside [workStartHour, workEndHour) on
// each day of the window, after removing busy events (availability != free).
// Pure over a CalendarStore; FreeCommand parses --duration/--within and calls
// this. This is "my own free time" — it does not coordinate with other people.

import Foundation

public func runFree(
    store: CalendarStore,
    window: DateInterval,
    minDuration: TimeInterval,
    workStartHour: Int = 9,
    workEndHour: Int = 18,
    calendars: [String] = [],
    hiddenCalendars: [String] = [],
    showAll: Bool = false,
    json: Bool = false,
    color: Bool = false,
    aligned: Bool = false,
    dateStyle: Output.DateStyle = .iso,
    now: Date = Date(),
    timeZone: TimeZone = .current
) -> String {
    let events = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    // Hide-list: a hidden calendar's events don't count as busy (consistent with
    // it being excluded from listings) unless --all or an explicit --calendar.
    let considered = (!showAll && calendars.isEmpty && !hiddenCalendars.isEmpty)
        ? events.filter { !$0.matchesCalendar(hiddenCalendars) }
        : events
    // Busy = anything not explicitly "free"; skip zero-length events.
    let busy = considered
        .filter { $0.availability != "free" && $0.end > $0.start }
        .map { DateInterval(start: $0.start, end: $0.end) }

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    var slots: [DateInterval] = []
    var day = cal.startOfDay(for: window.start)
    while day < window.end {
        // Hour 24 = the next midnight (bySettingHour: 24 would return nil).
        let we = workEndHour == 24
            ? cal.date(byAdding: .day, value: 1, to: day)
            : cal.date(bySettingHour: workEndHour, minute: 0, second: 0, of: day)
        if let ws = cal.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day),
           let we, we > ws {
            let lo = max(ws, window.start), hi = min(we, window.end)
            if hi > lo {
                slots += freeGaps(in: DateInterval(start: lo, end: hi), busy: busy, minDuration: minDuration)
            }
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: day), next > day else { break }
        day = next
    }

    if json {
        struct Slot: Encodable { let start: Date; let end: Date; let minutes: Int }
        return Output.ndjson(slots.map { Slot(start: $0.start, end: $0.end, minutes: Int($0.duration / 60)) })
    }
    // Empty output for no slots, matching agenda/search (Output.table([]) == "") so
    // scripts can treat empty as "no rows". Ink & Token: the free span is the
    // primary element (bold); the duration is green — an earned accent, "this
    // much open time", rhyming with rw=green and sync's +created.
    let rows = slots.map { s -> [String] in
        [
            Output.paint(Output.formatInstant(s.start, style: dateStyle, now: now, timeZone: timeZone), .bold, enabled: color),
            Output.paint(Output.formatInstant(s.end, style: dateStyle, now: now, timeZone: timeZone), .bold, enabled: color),
            Output.paint("(\(durationText(s.duration)))", .green, enabled: color),
        ]
    }
    return Output.table(rows, aligned: aligned)
}

/// Open sub-intervals of `workday` not covered by `busy`, each ≥ minDuration.
func freeGaps(in workday: DateInterval, busy: [DateInterval], minDuration: TimeInterval) -> [DateInterval] {
    // Clip busy to the workday, sort, and merge overlaps.
    let clipped = busy.compactMap { workday.intersection(with: $0) }.sorted { $0.start < $1.start }
    var merged: [DateInterval] = []
    for iv in clipped {
        if let last = merged.last, iv.start <= last.end {
            merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
        } else {
            merged.append(iv)
        }
    }
    // Gaps before/between/after the merged busy blocks.
    var gaps: [DateInterval] = []
    var cursor = workday.start
    for b in merged {
        if b.start.timeIntervalSince(cursor) >= minDuration { gaps.append(DateInterval(start: cursor, end: b.start)) }
        cursor = max(cursor, b.end)
    }
    if workday.end.timeIntervalSince(cursor) >= minDuration { gaps.append(DateInterval(start: cursor, end: workday.end)) }
    return gaps
}

private func durationText(_ t: TimeInterval) -> String {
    let total = Int(t)
    if total < 60 { return "\(total)s" }           // sub-minute slot: seconds, not "0m"
    let mins = total / 60, h = mins / 60, m = mins % 60
    if h > 0, m > 0 { return "\(h)h\(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}
