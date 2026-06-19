// Commands/Add.swift — `maccal add <title>`.
//
// Creates a new event and echoes it back like `show`. Pure logic over a
// CalendarStore + an injected Confirmer, so the validate / preview / confirm /
// abort branches are all testable with no TCC, EventKit, or terminal.
// AddCommand in main.swift parses flags, gates write access, picks the
// confirmer, and maps MaccalError to stderr + exit 1.

import Foundation

/// - Parameters:
///   - confirm: decides whether to write (ignored when dryRun).
///   - now/timeZone: injected for deterministic checks.
/// - Throws: WriteValidationError / DateTime.ParseError / WriteError (all MaccalError).
public func runAdd(
    store: CalendarStore,
    title: String,
    start: String,
    end: String?,
    duration: String?,
    allDay: Bool,
    calendar: String?,
    tz: String?,
    location: String?,
    notes: String?,
    url: String?,
    availability: String?,
    json: Bool,
    dryRun: Bool,
    confirm: Confirmer,
    now: Date,
    timeZone: TimeZone = .current
) throws -> WriteResult {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { throw WriteValidationError.emptyTitle }

    let zone = try resolveTimeZone(tz, fallback: timeZone)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone

    let (startDate, startDateOnly) = try DateTime.parse(start, now: now, timeZone: zone)

    // Resolve the exclusive end from exactly one of --end / --duration; a
    // date-only start with neither defaults to the next day (all-day).
    let endDate: Date
    var endDateOnly: Bool?
    if let end {
        guard duration == nil else { throw WriteValidationError.endAndDurationConflict }
        let parsed = try DateTime.parse(end, now: now, timeZone: zone)
        endDate = parsed.date
        endDateOnly = parsed.isDateOnly
    } else if let duration {
        endDate = cal.date(byAdding: try DateTime.parseDuration(duration), to: startDate)!
    } else if startDateOnly {
        endDate = cal.date(byAdding: .day, value: 1, to: startDate)!
    } else {
        throw WriteValidationError.missingEnd
    }

    // All-day iff explicitly requested or both bounds are date-only; mixing a
    // date-only and a timed bound is an error, never a silent coercion.
    let effectiveAllDay: Bool
    if allDay {
        guard startDateOnly, endDateOnly ?? true else { throw WriteValidationError.allDayWithTime }
        effectiveAllDay = true
    } else {
        if let endDateOnly, endDateOnly != startDateOnly { throw WriteValidationError.allDayWithTime }
        effectiveAllDay = startDateOnly
    }

    guard endDate > startDate else { throw WriteValidationError.endNotAfterStart }
    if effectiveAllDay {
        // An all-day event must span whole days — both bounds at local midnight
        // (rejects a sub-day --duration like 90m that the --end form already blocks).
        guard cal.startOfDay(for: startDate) == startDate, cal.startOfDay(for: endDate) == endDate else {
            throw WriteValidationError.allDayWithTime
        }
    }

    let avail = try validateAvailability(availability ?? "busy")
    let urlStr = url ?? ""
    if !urlStr.isEmpty, URL(string: urlStr) == nil { throw WriteValidationError.invalidURL(urlStr) }

    let draft = EventDraft(
        title: cleanTitle, start: startDate, end: endDate, allDay: effectiveAllDay,
        calendar: calendar, timeZoneId: effectiveAllDay ? nil : zone.identifier,
        location: location ?? "", notes: notes ?? "", url: urlStr, availability: avail
    )

    func render(_ e: EventInfo) -> String { json ? Output.jsonLine(e) : eventDetailText(e, timeZone: zone) }
    let preview = previewInfo(draft)

    if dryRun { return .dryRun(render(preview)) }
    guard confirm.confirm("Create this event?\n" + eventDetailText(preview, timeZone: zone)) else { return .aborted }
    return .wrote(render(try store.createEvent(draft)))
}

/// A display-only EventInfo from a draft (no id yet; calendar shown as the
/// selector, or "(default)") for the preview / confirmation prompt.
private func previewInfo(_ d: EventDraft) -> EventInfo {
    EventInfo(
        id: "", calendar: d.calendar ?? "(default)", calendarId: "",
        title: d.title, start: d.start, end: d.end, allDay: d.allDay,
        timeZone: d.timeZoneId ?? "", location: d.location, notes: d.notes, url: d.url,
        status: "confirmed", availability: d.availability, organizer: "", attendees: [], recurring: false
    )
}
