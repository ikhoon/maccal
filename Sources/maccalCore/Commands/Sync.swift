// Commands/Sync.swift — `maccal sync --from <src>… --to <dst>`.
//
// One-way mirror of one or more source calendars into a target calendar over a
// date window. `--from` repeats (union of sources). Each selector is
// "Account/Calendar" or a bare title/identifier, so names that repeat across
// accounts (e.g. two "Holidays") can be disambiguated.
//
// Idempotent: every copied event carries a hidden marker in its url —
// maccal-sync://<startEpoch>/<srcId> — naming the source occurrence, so
// re-running creates new events, updates changed ones, and (unless --no-delete)
// removes ones whose source occurrence is gone (plus any duplicate copies of the
// same source occurrence, so it converges to exactly one). Only marker-bearing
// events in the target are ever touched; the user's own events are left alone.
//
// A recurring source series is mirrored as ONE rule-bearing event (its anchor
// start/end + recurrence rule), keyed by source id alone — not one copy per
// occurrence (which would flood the target and trigger an invite mail each).
// Occurrences cancelled at the source (e.g. "skip this week") are then excluded
// from the copy by cancelling the matching occurrence on the target series —
// EventKit has no EXDATE-write, so `cancelOccurrence` removes that one occurrence.
//
// Pure logic over CalendarStore + Confirmer — resolve/plan/confirm/mirror
// branches are all testable with no TCC or EventKit.

import Foundation

/// How much of each source event to copy into the target.
public enum SyncDetail: Sendable, Equatable {
    case titleTimeLocation   // default: title + when + location
    case withNotes           // + notes body
    case busy                // opaque "Busy", time only (max privacy)

    var showsRealTitle: Bool { self != .busy }
    var showsLocation: Bool { self != .busy }
    var showsNotes: Bool { self == .withNotes }
}

private let syncScheme = "maccal-sync"

/// Hidden marker stored in a copied event's url, naming the source occurrence
/// (event id + start). Percent-encoded so it's a valid URL EventKit will keep.
public func makeSyncMarker(srcId: String, start: Date) -> String {
    let epoch = Int(start.timeIntervalSinceReferenceDate.rounded())
    let enc = srcId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? srcId
    return "\(syncScheme)://\(epoch)/\(enc)"
}

/// Parse a copied event's url back into (srcId, start); nil when not a marker.
public func parseSyncMarker(_ url: String) -> (srcId: String, start: Date)? {
    let prefix = "\(syncScheme)://"
    guard url.hasPrefix(prefix) else { return nil }
    let parts = url.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let epoch = Double(parts[0]) else { return nil }
    let srcId = String(parts[1]).removingPercentEncoding ?? String(parts[1])
    return (srcId, Date(timeIntervalSinceReferenceDate: epoch))
}

/// Occurrence key (id + rounded start). Non-recurring occurrences of the same
/// id (there are none) or distinct single events are keyed by (id, start).
private func occKey(_ id: String, _ start: Date) -> String {
    "\(id)\u{0}\(Int(start.timeIntervalSinceReferenceDate.rounded()))"
}

/// Occurrence start-dates the target copy still has but the source series no
/// longer does (cancelled at the source) — to be excluded from the copy.
/// Compared at whole-second resolution.
public func occurrencesToCancel(sourceDates: [Date], targetDates: [Date]) -> [Date] {
    let src = Set(sourceDates.map { Int($0.timeIntervalSinceReferenceDate.rounded()) })
    return targetDates.filter { !src.contains(Int($0.timeIntervalSinceReferenceDate.rounded())) }
}

/// Identity key matching a source event to its target copy. A recurring series
/// is keyed by source id alone — one rule-bearing copy for the whole series — so
/// occurrences aren't exploded; a single event is keyed by (id, start).
private func syncKey(srcId: String, start: Date, recurring: Bool) -> String {
    recurring ? "R\u{0}\(srcId)" : occKey(srcId, start)
}

/// Resolve a selector to one or more calendars. Forms:
///   "Account/*"        → every calendar in that account (source title)
///   "Account/Calendar" → the calendar with that title in that account
///   "Title" / id       → the calendar with that title or identifier
/// A non-wildcard selector must resolve to exactly one calendar.
func resolveSelectors(_ sel: String, in cals: [CalendarInfo]) throws -> [CalendarInfo] {
    if let slash = sel.firstIndex(of: "/") {
        let account = String(sel[..<slash])
        let name = String(sel[sel.index(after: slash)...])
        if name == "*" {
            let all = cals.filter { $0.source.localizedCaseInsensitiveCompare(account) == .orderedSame }
            guard !all.isEmpty else { throw WriteError.calendarNotFound(sel) }
            return all
        }
        let m = cals.filter {
            $0.source.localizedCaseInsensitiveCompare(account) == .orderedSame
                && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !m.isEmpty else { throw WriteError.calendarNotFound(sel) }
        guard m.count == 1 else { throw WriteError.ambiguousCalendar(sel) }
        return m
    }
    let m = cals.filter {
        $0.title.localizedCaseInsensitiveCompare(sel) == .orderedSame
            || $0.calendarIdentifier.caseInsensitiveCompare(sel) == .orderedSame
    }
    guard !m.isEmpty else { throw WriteError.calendarNotFound(sel) }
    guard m.count == 1 else { throw WriteError.ambiguousCalendar(sel) }
    return m
}

public func runSync(
    store: CalendarStore,
    from: [String],
    to: String,
    since: String?,
    until: String?,
    detail: SyncDetail,
    noDelete: Bool,
    json: Bool,
    dryRun: Bool,
    confirm: Confirmer,
    now: Date,
    timeZone: TimeZone = .current
) throws -> WriteResult {
    let cals = store.calendars()
    // Sources may include "Account/*" wildcards; flatten and de-dup by identifier.
    var seenSrc = Set<String>()
    let srcCals = try from.flatMap { try resolveSelectors($0, in: cals) }
        .filter { seenSrc.insert($0.calendarIdentifier).inserted }
    let dstMatches = try resolveSelectors(to, in: cals)
    guard dstMatches.count == 1 else { throw WriteError.ambiguousCalendar(to) }
    let dst = dstMatches[0]
    let srcIds = srcCals.map(\.calendarIdentifier)
    guard !srcIds.contains(dst.calendarIdentifier) else { throw WriteValidationError.sameSourceTarget }
    guard dst.writable else { throw WriteError.notWritable }

    let window = try DateWindow.window(from: since, to: until, now: now, timeZone: timeZone,
                                       defaultFromDays: 0, defaultSpanDays: 30)

    let sourceEvents = store.events(in: window, calendars: srcIds)
    let targetEvents = store.events(in: window, calendars: [dst.calendarIdentifier])

    // Index previously-synced copies by source key. Extra copies of the same
    // source occurrence (duplicate markers) are queued for deletion so sync
    // converges back to exactly one copy.
    var syncedByKey: [String: EventInfo] = [:]
    var duplicates: [EventInfo] = []
    for t in targetEvents {
        guard let m = parseSyncMarker(t.url) else { continue }
        let key = syncKey(srcId: m.srcId, start: m.start, recurring: t.recurring)
        if syncedByKey[key] == nil { syncedByKey[key] = t } else { duplicates.append(t) }
    }

    // What we WANT in the target for a given source occurrence.
    func desiredDraft(_ s: EventInfo) -> EventDraft {
        let title = detail.showsRealTitle ? (s.title.isEmpty ? "(untitled)" : s.title) : "Busy"
        // In busy mode force availability to busy too — copying "free" would leak
        // that the hidden block is low-priority.
        let avail = detail == .busy
            ? "busy"
            : (["busy", "free", "tentative", "unavailable"].contains(s.availability) ? s.availability : "busy")
        return EventDraft(
            title: title, start: s.start, end: s.end, allDay: s.allDay,
            calendar: dst.calendarIdentifier,
            // Pass the source zone through verbatim (incl. "" = floating) so an
            // update can clear a stale zone; all-day floats (nil).
            timeZoneId: s.allDay ? nil : s.timeZone,
            location: detail.showsLocation ? s.location : "",
            notes: detail.showsNotes ? s.notes : "",
            url: makeSyncMarker(srcId: s.id, start: s.start),
            availability: avail,
            recurrenceRule: s.recurrenceRule
        )
    }

    // The marker/url is the identity key (always equal), so it's not compared.
    func upToDate(_ t: EventInfo, _ d: EventDraft) -> Bool {
        let expectedTZ = d.allDay ? "" : (d.timeZoneId ?? "")
        return t.title == d.title && t.start == d.start && t.end == d.end && t.allDay == d.allDay
            && t.timeZone == expectedTZ && t.location == d.location && t.notes == d.notes
            && t.availability == d.availability && t.recurrenceRule == d.recurrenceRule
    }

    var sourceKeys = Set<String>()
    var handledRecurring = Set<String>()
    var recurringSourceIds: [String] = []       // recurring series ids that were synced
    var existingCopyId: [String: String] = [:]  // recurring source id -> its existing copy id
    var toCreate: [EventDraft] = []
    var toUpdate: [(id: String, changes: EventChanges, draft: EventDraft, span: WriteSpan)] = []
    for s in sourceEvents {
        // A recurring series expands to many occurrences sharing one id; copy it
        // ONCE as a rule-bearing event, using the series anchor (its start/end +
        // recurrenceRule) rather than each occurrence, so the target doesn't get
        // one copy (and one invite mail) per occurrence.
        let src: EventInfo
        if s.recurring {
            guard handledRecurring.insert(s.id).inserted else { continue }
            src = store.event(id: s.id) ?? s
        } else {
            src = s
        }
        if src.recurring { recurringSourceIds.append(src.id) }
        let key = syncKey(srcId: src.id, start: src.start, recurring: src.recurring)
        sourceKeys.insert(key)
        let d = desiredDraft(src)
        if let existing = syncedByKey[key] {
            if src.recurring { existingCopyId[src.id] = existing.id }
            if !upToDate(existing, d) {
                // A recurring copy is written as the whole series (.futureEvents);
                // a single event touches only itself (.thisEvent).
                toUpdate.append((existing.id, EventChanges(
                    title: d.title, start: d.start, end: d.end, allDay: d.allDay,
                    timeZoneId: d.timeZoneId, location: d.location, notes: d.notes,
                    availability: d.availability, recurrenceRule: d.recurrenceRule
                ), d, src.recurring ? .futureEvents : .thisEvent))
            }
        } else {
            toCreate.append(d)
        }
    }
    // Delete orphaned copies + duplicate copies (unless --no-delete keeps all).
    var toDelete: [EventInfo] = []
    if !noDelete {
        for (key, t) in syncedByKey where !sourceKeys.contains(key) { toDelete.append(t) }
        toDelete.append(contentsOf: duplicates)
    }

    // Pre-write estimate of cancellations on already-existing copies, used only
    // for the dry-run preview and the "nothing to do" check. The authoritative
    // set is recomputed AFTER writes (an update can change a copy's occurrences).
    var existingCancel: [(copyId: String, dates: [Date])] = []
    for sid in recurringSourceIds {
        guard let copyId = existingCopyId[sid] else { continue }
        let dates = occurrencesToCancel(
            sourceDates: store.seriesOccurrences(id: sid, in: window),
            targetDates: store.seriesOccurrences(id: copyId, in: window))
        if !dates.isEmpty { existingCancel.append((copyId, dates)) }
    }
    let existingCancelCount = existingCancel.reduce(0) { $0 + $1.dates.count }
    let newRecurring = toCreate.contains { $0.recurrenceRule != nil }

    func whenOf(_ start: Date, _ allDay: Bool) -> String {
        allDay ? Output.localDate(start, timeZone: timeZone) : Output.localISO(start, timeZone: timeZone)
    }

    let sources = srcCals.map(\.title).joined(separator: ", ")
    let label = "\(sources) → \(dst.title)"

    if toCreate.isEmpty, toUpdate.isEmpty, toDelete.isEmpty, existingCancelCount == 0 {
        if json {
            return .wrote(Output.jsonLine(SyncSummary(source: sources, target: dst.title, created: 0, updated: 0, deleted: 0, cancelled: 0)))
        }
        return .wrote("sync: already up to date — \(label) (\(sourceEvents.count) events in window)")
    }

    func plan(_ verb: String) -> String {
        var lines = ["\(verb): \(label)   +\(toCreate.count) new  ~\(toUpdate.count) changed  -\(toDelete.count) removed  ✂\(existingCancelCount) cancelled"]
        for d in toCreate.sorted(by: { $0.start < $1.start }) { lines.append("  + \(whenOf(d.start, d.allDay))  \(d.title)") }
        for u in toUpdate.sorted(by: { $0.draft.start < $1.draft.start }) { lines.append("  ~ \(whenOf(u.draft.start, u.draft.allDay))  \(u.draft.title)") }
        for t in EventInfo.sortedByStart(toDelete) { lines.append("  - \(whenOf(t.start, t.allDay))  \(t.title)") }
        for c in existingCancel { for d in c.dates.sorted() { lines.append("  ✂ \(whenOf(d, false))  (cancelled occurrence)") } }
        if newRecurring { lines.append("  (cancelled occurrences on newly-created series are applied on write)") }
        return lines.joined(separator: "\n")
    }

    if dryRun { return .dryRun(plan("would sync")) }
    guard confirm.confirm(plan("sync") + "\n\nApply these changes to \(dst.title)?") else { return .aborted }

    var created = 0, updated = 0, deleted = 0, cancelled = 0
    var createdCopyId: [String: String] = [:]   // recurring source id -> new copy id
    for d in toCreate {
        let info = try store.createEvent(d); created += 1
        if d.recurrenceRule != nil, let m = parseSyncMarker(d.url) { createdCopyId[m.srcId] = info.id }
    }
    for u in toUpdate { _ = try store.updateEvent(id: u.id, u.changes, span: u.span); updated += 1 }
    // Recurring copies delete the whole series; single events delete just themselves.
    for t in toDelete { _ = try store.deleteEvent(id: t.id, span: t.recurring ? .futureEvents : .thisEvent); deleted += 1 }
    // Reflect source-side occurrence cancellations on the copies. Recomputed HERE
    // — after create/update — because an updated copy's occurrence dates (from a
    // start or recurrence-rule change) would be stale if diffed before the write.
    // Covers both existing and newly-created copies; the copy id comes from the
    // source series id via the marker.
    for sid in recurringSourceIds {
        guard let copyId = existingCopyId[sid] ?? createdCopyId[sid] else { continue }
        let dates = occurrencesToCancel(
            sourceDates: store.seriesOccurrences(id: sid, in: window),
            targetDates: store.seriesOccurrences(id: copyId, in: window))
        for d in dates { try store.cancelOccurrence(id: copyId, occurrence: d); cancelled += 1 }
    }

    if json {
        return .wrote(Output.jsonLine(SyncSummary(source: sources, target: dst.title, created: created, updated: updated, deleted: deleted, cancelled: cancelled)))
    }
    return .wrote("synced: \(label)   +\(created) new  ~\(updated) changed  -\(deleted) removed  ✂\(cancelled) cancelled")
}

private struct SyncSummary: Encodable {
    let source: String
    let target: String
    let created: Int
    let updated: Int
    let deleted: Int
    let cancelled: Int
}
