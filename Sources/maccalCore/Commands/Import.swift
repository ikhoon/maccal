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
    json: Bool = false,
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

    // Validate before previewing OR writing, so --dry-run and commit agree and a
    // malformed VEVENT (end <= start, or an all-day span not on whole days) fails
    // the whole batch up front rather than creating a degenerate event.
    var vcal = Calendar(identifier: .gregorian); vcal.timeZone = timeZone
    for d in resolved {
        guard d.end > d.start else { throw WriteValidationError.endNotAfterStart }
        if d.allDay {
            guard vcal.startOfDay(for: d.start) == d.start, vcal.startOfDay(for: d.end) == d.end else {
                throw WriteValidationError.allDayWithTime
            }
        }
    }

    if dryRun {
        if json {
            struct Plan: Encodable { let action, title: String; let start, end: Date; let allDay: Bool; let calendar: String? }
            return .dryRun(Output.ndjson(resolved.map {
                Plan(action: "would-import", title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay, calendar: $0.calendar)
            }))
        }
        return .dryRun("would import \(resolved.count) event(s):\n\(previewText(resolved, timeZone: timeZone))\n")
    }
    guard confirm.confirm("Import \(resolved.count) event(s)?\n\(previewText(resolved, timeZone: timeZone))\n") else { return .aborted }
    // Best-effort rollback: if one create fails, remove the ones already made so a
    // retry doesn't duplicate a half-imported batch.
    var created: [EventInfo] = []
    do {
        for d in resolved { created.append(try store.createEvent(d)) }
    } catch {
        for e in created { _ = try? store.deleteEvent(id: e.id, span: .thisEvent) }
        throw error
    }
    if json { return .wrote(Output.eventsNDJSON(created)) }
    return .wrote("imported \(created.count) event(s)\n")
}

/// The human confirm/dry-run preview: one `+ <when>  <title>` line per draft.
private func previewText(_ drafts: [EventDraft], timeZone: TimeZone) -> String {
    drafts.map {
        let when = $0.allDay ? Output.localDate($0.start, timeZone: timeZone) : Output.localISO($0.start, timeZone: timeZone)
        return "  + \(when)  \(Output.sanitize($0.title))"
    }.joined(separator: "\n")
}
