// Commands/Edit.swift — `maccal edit <id>`.
//
// Patches fields of an existing event and echoes the result like `show`. Pure
// logic over a CalendarStore + an injected Confirmer. runEdit fetches the
// current event first (it needs the old start/end for the keep-duration rule and
// the before→after diff), builds a sparse EventChanges, and updates.
//
// Note: converting between all-day and timed (--all-day/--no-all-day) is
// deferred; runEdit preserves the event's existing all-day-ness and snaps
// all-day bounds to local midnight.

import Foundation

public func runEdit(
    store: CalendarStore,
    id: String,
    title: String?,
    start: String?,
    end: String?,
    duration: String?,
    tz: String?,
    location: String?,
    notes: String?,
    url: String?,
    availability: String?,
    calendar: String?,
    allOccurrences: Bool,
    json: Bool,
    dryRun: Bool,
    confirm: Confirmer,
    now: Date,
    timeZone: TimeZone = .current
) throws -> WriteResult {
    let hasFieldFlag = title != nil || start != nil || end != nil || duration != nil
        || tz != nil || location != nil || notes != nil || url != nil || availability != nil
        || calendar != nil
    guard hasFieldFlag else { throw WriteValidationError.noChanges }
    if end != nil, duration != nil { throw WriteValidationError.endAndDurationConflict }

    // Occurrence handle "<id>@<epoch>" (agenda/search print it for recurring rows):
    // detach-edit just that occurrence. Non-schedule fields only — rescheduling one
    // occurrence is a bigger change (use --all-occurrences, or rm + add).
    if let occ = Output.parseOccurrenceHandle(id), let series = store.event(id: occ.id), series.recurring {
        guard start == nil, end == nil, duration == nil, tz == nil, calendar == nil, !allOccurrences else {
            throw WriteValidationError.occurrenceScheduleUnsupported
        }
        var occChanges = EventChanges()
        if let title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw WriteValidationError.emptyTitle }
            occChanges.title = t
        }
        if let location { occChanges.location = location }
        if let notes { occChanges.notes = notes }
        if let url {
            if !url.isEmpty, URL(string: url) == nil { throw WriteValidationError.invalidURL(url) }
            occChanges.url = url
        }
        if let availability { occChanges.availability = try validateAvailability(availability) }
        guard !occChanges.isEmpty else { throw WriteValidationError.noChanges }

        let before = series.detachedOccurrence(at: occ.start)
        let after = before.applying(occChanges)
        if dryRun { return .dryRun(json ? Output.jsonLine(after) : diffText(before, after, timeZone: timeZone)) }
        guard confirm.confirm(diffText(before, after, timeZone: timeZone) + "Apply to this occurrence only?") else { return .aborted }
        let updated = try store.updateOccurrence(id: occ.id, occurrence: occ.start, occChanges)
        return .wrote(json ? Output.jsonLine(updated) : eventDetailText(updated, timeZone: timeZone))
    }

    guard let current = store.event(id: id) else { throw WriteError.notFound(id) }
    // An id resolves a recurring series to its anchor, not the occurrence the user
    // saw — editing one occurrence isn't possible yet, so require the whole series.
    if current.recurring, !allOccurrences { throw WriteValidationError.recurringRequiresAllOccurrences }

    // Parse new bounds in --tz, else the event's authoring zone, else local.
    // --tz is validated always, but a floating all-day event ignores it: its
    // date-only bounds are snapped in the display zone so the calendar day can't
    // shift under a foreign --tz.
    let resolvedZone = try resolveTimeZone(tz, fallback: TimeZone(identifier: current.timeZone) ?? timeZone)
    let parseZone = current.allDay ? timeZone : resolvedZone
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = parseZone

    let newStartRaw: Date
    var startTimed = false
    if let start {
        let p = try DateTime.parse(start, now: now, timeZone: parseZone)
        newStartRaw = p.date
        startTimed = !p.isDateOnly
    } else {
        newStartRaw = current.start
    }

    let newEndRaw: Date
    var endTimed = false
    if let end {
        let p = try DateTime.parse(end, now: now, timeZone: parseZone)
        newEndRaw = p.date
        endTimed = !p.isDateOnly
    } else if let duration {
        newEndRaw = cal.date(byAdding: try DateTime.parseDuration(duration), to: newStartRaw)!
    } else if start != nil {
        // Start moved with no new end: keep the wall-clock duration. Adding the
        // raw second delta drifts across a DST boundary (a 1h event could become
        // 0h/2h), so re-add the original span in calendar components — DST-safe,
        // matching the date math everywhere else.
        let span = cal.dateComponents([.day, .hour, .minute, .second], from: current.start, to: current.end)
        newEndRaw = cal.date(byAdding: span, to: newStartRaw)
            ?? current.end.addingTimeInterval(newStartRaw.timeIntervalSince(current.start))
    } else {
        newEndRaw = current.end
    }

    // Preserve all-day-ness (no toggle in M3). All-day bounds carry no clock time
    // and span whole days; snap (DST-safe) and reject a timed/sub-day change.
    let datesChanged = start != nil || end != nil || duration != nil
    let newStart: Date
    let newEnd: Date
    if current.allDay {
        guard !startTimed, !endTimed else { throw WriteValidationError.allDayWithTime }
        // A sub-day --duration/--end can't apply to an all-day event — reject it
        // rather than silently snapping to a day boundary.
        if (duration != nil || end != nil), cal.startOfDay(for: newEndRaw) != newEndRaw {
            throw WriteValidationError.allDayWithTime
        }
        newStart = cal.startOfDay(for: newStartRaw)
        newEnd = cal.startOfDay(for: newEndRaw)
        if datesChanged { guard newEnd > newStart else { throw WriteValidationError.allDayWithTime } }
    } else {
        newStart = newStartRaw
        newEnd = newEndRaw
        if datesChanged { guard newEnd > newStart else { throw WriteValidationError.endNotAfterStart } }
    }

    var changes = EventChanges()
    if let title {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw WriteValidationError.emptyTitle }
        changes.title = t
    }
    if start != nil { changes.start = newStart }
    if datesChanged { changes.end = newEnd }
    if tz != nil, !current.allDay { changes.timeZoneId = parseZone.identifier } // canonicalized, like add; ignored for floating all-day
    if let location { changes.location = location }
    if let notes { changes.notes = notes }
    if let url {
        if !url.isEmpty, URL(string: url) == nil { throw WriteValidationError.invalidURL(url) }
        changes.url = url
    }
    if let availability { changes.availability = try validateAvailability(availability) }
    var movedTarget: CalendarInfo?
    if let calendar {
        // Resolve + validate now so a bad --calendar fails on --dry-run too.
        let matches = store.calendars().filter {
            $0.title.localizedCaseInsensitiveCompare(calendar) == .orderedSame
                || $0.calendarIdentifier.caseInsensitiveCompare(calendar) == .orderedSame
        }
        guard matches.count == 1, let target = matches.first else {
            throw matches.isEmpty ? WriteError.calendarNotFound(calendar) : WriteError.ambiguousCalendar(calendar)
        }
        guard target.writable else { throw WriteError.notWritable }
        changes.calendar = calendar   // keep the user's selector; the store resolves it
        movedTarget = target
    }

    var after = current.applying(changes)
    if let t = movedTarget {
        // applying can't resolve the selector → (title, id); fix the preview so the
        // diff and --dry-run --json show the real target calendar.
        after = after.movingTo(calendar: t.title, calendarId: t.calendarIdentifier)
    }
    if dryRun {
        return .dryRun(json ? Output.jsonLine(after) : diffText(current, after, timeZone: parseZone))
    }

    let question = allOccurrences ? "Apply to this and all future occurrences?" : "Apply these changes?"
    guard confirm.confirm(diffText(current, after, timeZone: parseZone) + question) else { return .aborted }

    let updated = try store.updateEvent(id: id, changes, span: allOccurrences ? .futureEvents : .thisEvent)
    return .wrote(json ? Output.jsonLine(updated) : eventDetailText(updated, timeZone: parseZone))
}

/// A compact before→after listing of only the fields that change.
private func diffText(_ before: EventInfo, _ after: EventInfo, timeZone: TimeZone) -> String {
    func when(_ e: EventInfo) -> String {
        e.allDay
            ? Output.localDate(e.start, timeZone: timeZone)
            : "\(Output.localISO(e.start, timeZone: timeZone)) — \(Output.localISO(e.end, timeZone: timeZone))"
    }
    func show(_ s: String) -> String { s.isEmpty ? "(none)" : Output.sanitize(s) }

    var lines: [String] = []
    if before.title != after.title { lines.append("Title: \(show(before.title)) → \(show(after.title))") }
    if before.calendar != after.calendar { lines.append("Calendar: \(show(before.calendar)) → \(show(after.calendar))") }
    if when(before) != when(after) { lines.append("When: \(when(before)) → \(when(after))") }
    if before.location != after.location { lines.append("Location: \(show(before.location)) → \(show(after.location))") }
    if before.notes != after.notes { lines.append("Notes: \(show(before.notes)) → \(show(after.notes))") }
    if before.url != after.url { lines.append("URL: \(show(before.url)) → \(show(after.url))") }
    if before.availability != after.availability { lines.append("Availability: \(before.availability) → \(after.availability)") }
    if before.timeZone != after.timeZone { lines.append("TimeZone: \(show(before.timeZone)) → \(show(after.timeZone))") }
    return (lines.isEmpty ? "(no effective change)" : lines.joined(separator: "\n")) + "\n"
}
