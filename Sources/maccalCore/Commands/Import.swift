// Commands/Import.swift — `maccal import <file.ics>`.
//
// Creates events parsed from iCalendar text (ICS.parse). Pure over a
// CalendarStore + Confirmer; ImportCommand in main.swift reads the file and
// gates write access. Confirms once for the whole batch (declined = write
// nothing); --dry-run previews the events without creating them.

import Foundation

public func runImport(
    store: CalendarStore,
    drafts: [EventDraft],
    calendar: String?,
    dryRun: Bool,
    confirm: Confirmer,
    timeZone: TimeZone = .current
) throws -> WriteResult {
    guard !drafts.isEmpty else { throw WriteValidationError.noEventsToImport }
    // Override the target calendar when --calendar is given (ICS carries none).
    let resolved = drafts.map { d -> EventDraft in
        guard let calendar else { return d }
        return EventDraft(
            title: d.title, start: d.start, end: d.end, allDay: d.allDay,
            calendar: calendar, timeZoneId: d.timeZoneId, location: d.location,
            notes: d.notes, url: d.url, availability: d.availability, recurrenceRule: d.recurrenceRule)
    }
    let preview = resolved.map {
        let when = $0.allDay ? Output.localDate($0.start, timeZone: timeZone) : Output.localISO($0.start, timeZone: timeZone)
        return "  + \(when)  \(Output.sanitize($0.title))"
    }.joined(separator: "\n")

    if dryRun { return .dryRun("would import \(resolved.count) event(s):\n\(preview)\n") }
    guard confirm.confirm("Import \(resolved.count) event(s)?\n\(preview)\n") else { return .aborted }
    for d in resolved { _ = try store.createEvent(d) }
    return .wrote("imported \(resolved.count) event(s)\n")
}
