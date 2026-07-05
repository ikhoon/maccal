// Commands/ResolveId.swift — turn a short git-style id back into a full handle.
//
// agenda/search show a 7-char `shortId` (a hash of the event handle) instead of
// the long EK identifier. show/edit/rm/export accept either the full id/handle
// OR that short code; this resolves the short code by scanning a ±1-year window
// and matching each occurrence's shortId. A full id/handle is returned untouched
// (no fetch), so the common path stays cheap. Pure over CalendarStore, testable.

import Foundation

/// Resolve an event token to a full id/handle. A full EK id/handle passes
/// through unchanged. A `shortId` (7 hex chars) is looked up over a window and
/// mapped to its unique event handle; throws `WriteError.notFound` when nothing
/// matches and `.ambiguousShortId` when more than one does.
public func resolveEventToken(
    _ token: String,
    store: CalendarStore,
    now: Date = Date(),
    timeZone: TimeZone = .current
) throws -> String {
    guard Output.isShortId(token) else { return token }   // a full id/handle — use as-is
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let start = cal.date(byAdding: .year, value: -1, to: now) ?? now
    let end = cal.date(byAdding: .year, value: 1, to: now) ?? now
    let events = store.events(in: DateInterval(start: start, end: end), calendars: nil)
    // Match each occurrence's handle; dedupe by handle so a recurring series'
    // repeated occurrences don't read as ambiguous when they share a short code
    // only if their handles differ (they won't — handle carries the start).
    var byHandle: [String: EventInfo] = [:]
    for e in events where Output.shortId(e.handle) == token { byHandle[e.handle] = e }
    switch byHandle.count {
    case 0: throw WriteError.notFound(token)
    case 1: return byHandle.keys.first!
    default: throw WriteError.ambiguousShortId(token)
    }
}
