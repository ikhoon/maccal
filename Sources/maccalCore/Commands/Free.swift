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
    json: Bool = false,
    timeZone: TimeZone = .current
) -> String {
    let events = store.events(in: window, calendars: calendars.isEmpty ? nil : calendars)
    // Busy = anything not explicitly "free"; skip zero-length events.
    let busy = events
        .filter { $0.availability != "free" && $0.end > $0.start }
        .map { DateInterval(start: $0.start, end: $0.end) }

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    var slots: [DateInterval] = []
    var day = cal.startOfDay(for: window.start)
    while day < window.end {
        if let ws = cal.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day),
           let we = cal.date(bySettingHour: workEndHour, minute: 0, second: 0, of: day), we > ws {
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
    if slots.isEmpty { return "no free slots\n" }
    let rows = slots.map {
        [Output.localISO($0.start, timeZone: timeZone), Output.localISO($0.end, timeZone: timeZone), "(\(durationText($0.duration)))"]
    }
    return Output.tsv(rows)
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
    let mins = Int(t / 60), h = mins / 60, m = mins % 60
    if h > 0, m > 0 { return "\(h)h\(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}
