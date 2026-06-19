// Commands/Rm.swift — `maccal rm <id>`.
//
// Deletes an event by id — destructive, so it confirms by default (declined
// unless the user types y/yes, or passes --yes). Pure logic over a
// CalendarStore + an injected Confirmer; RmCommand in main.swift gates write
// access and refuses to delete unattended on a non-TTY.

import Foundation

/// - Throws: WriteError.notFound when the id resolves to nothing (mapped to
///   exit 1), or .notWritable / .storeFailure from the delete.
public func runRm(
    store: CalendarStore,
    id: String,
    allOccurrences: Bool,
    json: Bool,
    dryRun: Bool,
    confirm: Confirmer,
    timeZone: TimeZone = .current
) throws -> WriteResult {
    guard let event = store.event(id: id) else { throw WriteError.notFound(id) }
    // An id resolves a recurring series to its anchor; deleting one occurrence
    // isn't possible yet, so require the whole series explicitly.
    if event.recurring, !allOccurrences { throw WriteValidationError.recurringRequiresAllOccurrences }

    // --json emits the full event (same shape as show/add/edit, all-day flag and
    // all) for both dry-run and success; text differs.
    func render(_ e: EventInfo) -> String { json ? Output.jsonLine(e) : eventDetailText(e, timeZone: timeZone) }

    if dryRun { return .dryRun(render(event)) } // show what would be deleted; remove nothing

    let question = allOccurrences ? "Delete this and all future occurrences?" : "Delete this event?"
    guard confirm.confirm(eventDetailText(event, timeZone: timeZone) + question) else { return .aborted }

    let deleted = try store.deleteEvent(id: id, span: allOccurrences ? .futureEvents : .thisEvent)
    return .wrote(json ? Output.jsonLine(deleted) : "deleted \(deleted.id) — \(Output.sanitize(deleted.title))\n")
}
