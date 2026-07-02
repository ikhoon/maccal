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

/// Occurrence key (id + rounded start). Recurring occurrences share an id but
/// differ by start, so each is mirrored as its own target event.
private func occKey(_ id: String, _ start: Date) -> String {
    "\(id)\u{0}\(Int(start.timeIntervalSinceReferenceDate.rounded()))"
}

/// Resolve a selector to exactly one calendar. A selector is either
/// "Account/Calendar" (source title + calendar title — to disambiguate a name
/// that repeats across accounts) or a bare calendar title / identifier.
func resolveCalendarSelector(_ sel: String, in cals: [CalendarInfo]) throws -> CalendarInfo {
    let matches: [CalendarInfo]
    if let slash = sel.firstIndex(of: "/") {
        let account = String(sel[..<slash])
        let title = String(sel[sel.index(after: slash)...])
        matches = cals.filter {
            $0.source.localizedCaseInsensitiveCompare(account) == .orderedSame
                && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }
    } else {
        matches = cals.filter {
            $0.title.localizedCaseInsensitiveCompare(sel) == .orderedSame
                || $0.calendarIdentifier.caseInsensitiveCompare(sel) == .orderedSame
        }
    }
    guard !matches.isEmpty else { throw WriteError.calendarNotFound(sel) }
    guard matches.count == 1 else { throw WriteError.ambiguousCalendar(sel) }
    return matches[0]
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
    let srcCals = try from.map { try resolveCalendarSelector($0, in: cals) }
    let dst = try resolveCalendarSelector(to, in: cals)
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
        let key = occKey(m.srcId, m.start)
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
            availability: avail
        )
    }

    // The marker/url is the identity key (always equal), so it's not compared.
    func upToDate(_ t: EventInfo, _ d: EventDraft) -> Bool {
        let expectedTZ = d.allDay ? "" : (d.timeZoneId ?? "")
        return t.title == d.title && t.start == d.start && t.end == d.end && t.allDay == d.allDay
            && t.timeZone == expectedTZ && t.location == d.location && t.notes == d.notes
            && t.availability == d.availability
    }

    var sourceKeys = Set<String>()
    var toCreate: [EventDraft] = []
    var toUpdate: [(id: String, changes: EventChanges, draft: EventDraft)] = []
    for s in sourceEvents {
        let key = occKey(s.id, s.start)
        sourceKeys.insert(key)
        let d = desiredDraft(s)
        if let existing = syncedByKey[key] {
            if !upToDate(existing, d) {
                toUpdate.append((existing.id, EventChanges(
                    title: d.title, start: d.start, end: d.end, allDay: d.allDay,
                    timeZoneId: d.timeZoneId, location: d.location, notes: d.notes, availability: d.availability
                ), d))
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

    func whenOf(_ start: Date, _ allDay: Bool) -> String {
        allDay ? Output.localDate(start, timeZone: timeZone) : Output.localISO(start, timeZone: timeZone)
    }

    let sources = srcCals.map(\.title).joined(separator: ", ")
    let label = "\(sources) → \(dst.title)"

    if toCreate.isEmpty, toUpdate.isEmpty, toDelete.isEmpty {
        if json {
            return .wrote(Output.jsonLine(SyncSummary(source: sources, target: dst.title, created: 0, updated: 0, deleted: 0)))
        }
        return .wrote("sync: already up to date — \(label) (\(sourceEvents.count) events in window)")
    }

    func plan(_ verb: String) -> String {
        var lines = ["\(verb): \(label)   +\(toCreate.count) new  ~\(toUpdate.count) changed  -\(toDelete.count) removed"]
        for d in toCreate.sorted(by: { $0.start < $1.start }) { lines.append("  + \(whenOf(d.start, d.allDay))  \(d.title)") }
        for u in toUpdate.sorted(by: { $0.draft.start < $1.draft.start }) { lines.append("  ~ \(whenOf(u.draft.start, u.draft.allDay))  \(u.draft.title)") }
        for t in EventInfo.sortedByStart(toDelete) { lines.append("  - \(whenOf(t.start, t.allDay))  \(t.title)") }
        return lines.joined(separator: "\n")
    }

    if dryRun { return .dryRun(plan("would sync")) }
    guard confirm.confirm(plan("sync") + "\n\nApply these changes to \(dst.title)?") else { return .aborted }

    var created = 0, updated = 0, deleted = 0
    for d in toCreate { _ = try store.createEvent(d); created += 1 }
    for u in toUpdate { _ = try store.updateEvent(id: u.id, u.changes, span: .thisEvent); updated += 1 }
    for t in toDelete { _ = try store.deleteEvent(id: t.id, span: .thisEvent); deleted += 1 }

    if json {
        return .wrote(Output.jsonLine(SyncSummary(source: sources, target: dst.title, created: created, updated: updated, deleted: deleted)))
    }
    return .wrote("synced: \(label)   +\(created) new  ~\(updated) changed  -\(deleted) removed")
}

private struct SyncSummary: Encodable {
    let source: String
    let target: String
    let created: Int
    let updated: Int
    let deleted: Int
}
