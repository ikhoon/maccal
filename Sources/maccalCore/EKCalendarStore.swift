// EKCalendarStore.swift — the real CalendarStore, backed by EKEventStore.
//
// This is the only file that talks to EventKit's data model directly; it maps
// EK* objects into the plain DTOs the rest of the tool uses. AppKit is imported
// solely to read NSColor (no GUI is launched in a CLI).

import AppKit
import EventKit
import Foundation

public final class EKCalendarStore: CalendarStore {
    let store: EKEventStore

    public init(store: EKEventStore) {
        self.store = store
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.calendarInfo)
    }

    public func defaultWritableCalendar() -> CalendarInfo? {
        store.defaultCalendarForNewEvents.map(Self.calendarInfo)
    }

    static func calendarInfo(_ cal: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            title: cal.title,
            source: cal.source?.title ?? "",
            type: typeString(cal.type),
            sourceType: sourceTypeString(cal.source?.sourceType),
            writable: cal.allowsContentModifications,
            color: hexColor(cal.color),
            calendarIdentifier: cal.calendarIdentifier
        )
    }

    public func events(in range: DateInterval, calendars: [String]?) -> [EventInfo] {
        // Empty / zero-length window can't contain anything.
        guard range.duration > 0 else { return [] }

        // Resolve selectors → calendars. nil/empty means "all event calendars";
        // selectors that match nothing mean an empty result (not "all").
        let scope: [EKCalendar]?
        if let selectors = calendars, !selectors.isEmpty {
            let matched = matchCalendars(selectors)
            if matched.isEmpty { return [] }
            scope = matched
        } else {
            scope = nil
        }

        // predicateForEvents supports a span of ~4 years; a single predicate over
        // a wider range silently drops events. Chunk, query each, then union.
        var fetched: [EventInfo] = []
        for chunk in Self.chunk(range) {
            let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: scope)
            fetched.append(contentsOf: store.events(matching: predicate).map(Self.eventInfo))
        }
        // The predicate result is unordered and chunk/calendar overlap can repeat
        // an occurrence — dedupe on (id, start), then impose canonical order.
        return EventInfo.sortedByStart(EventInfo.deduped(fetched))
    }

    public func event(id: String) -> EventInfo? {
        // event(withIdentifier:) consumes an eventIdentifier and, for a recurring
        // series, returns an anchor occurrence (typically the series start) — NOT
        // the specific occurrence shown in agenda/search, whose date the id alone
        // cannot carry. The result is flagged recurring:true.
        guard !id.isEmpty, let ev = store.event(withIdentifier: id) else { return nil }
        return Self.eventInfo(ev)
    }

    // MARK: - Writes

    public func createEvent(_ draft: EventDraft) throws -> EventInfo {
        let calendar = try resolveWritableCalendar(draft.calendar)
        let ev = EKEvent(eventStore: store) // must be bound to the saving store
        ev.calendar = calendar
        ev.title = draft.title
        ev.startDate = draft.start
        ev.endDate = draft.end
        ev.isAllDay = draft.allDay
        ev.timeZone = draft.allDay ? nil : draft.timeZoneId.flatMap(TimeZone.init(identifier:))
        if !draft.location.isEmpty { ev.location = draft.location }
        if !draft.notes.isEmpty { ev.notes = draft.notes }
        if !draft.url.isEmpty { ev.url = URL(string: draft.url) }
        ev.availability = Self.availabilityValue(draft.availability)
        if let rule = draft.recurrenceRule { ev.recurrenceRules = [Self.ekRecurrenceRule(rule)] }
        do {
            try store.save(ev, span: .thisEvent, commit: true) // commit now: a CLI has no run loop
        } catch {
            throw WriteError.storeFailure((error as NSError).localizedDescription)
        }
        return Self.eventInfo(ev) // eventIdentifier is populated only after save
    }

    public func updateEvent(id: String, _ changes: EventChanges, span: WriteSpan) throws -> EventInfo {
        guard !id.isEmpty, let ev = store.event(withIdentifier: id) else { throw WriteError.notFound(id) }
        guard ev.calendar?.allowsContentModifications ?? false else { throw WriteError.notWritable }

        if let t = changes.title { ev.title = t }
        if let s = changes.start { ev.startDate = s }
        if let e = changes.end { ev.endDate = e }
        if let ad = changes.allDay { ev.isAllDay = ad }
        if ev.isAllDay {
            ev.timeZone = nil // all-day events float
        } else if let tzid = changes.timeZoneId {
            ev.timeZone = TimeZone(identifier: tzid)
        }
        if let loc = changes.location { ev.location = loc.isEmpty ? nil : loc }
        if let n = changes.notes { ev.notes = n.isEmpty ? nil : n }
        if let u = changes.url { ev.url = u.isEmpty ? nil : URL(string: u) }
        if let av = changes.availability { ev.availability = Self.availabilityValue(av) }
        if let rule = changes.recurrenceRule { ev.recurrenceRules = [Self.ekRecurrenceRule(rule)] }
        if let sel = changes.calendar { ev.calendar = try resolveWritableCalendar(sel) }

        do {
            try store.save(ev, span: Self.ekSpan(span), commit: true)
        } catch {
            throw WriteError.storeFailure((error as NSError).localizedDescription)
        }
        return Self.eventInfo(ev)
    }

    public func deleteEvent(id: String, span: WriteSpan) throws -> EventInfo {
        guard !id.isEmpty, let ev = store.event(withIdentifier: id) else { throw WriteError.notFound(id) }
        guard ev.calendar?.allowsContentModifications ?? false else { throw WriteError.notWritable }
        let info = Self.eventInfo(ev) // capture before remove() invalidates the EKEvent
        do {
            try store.remove(ev, span: Self.ekSpan(span), commit: true)
        } catch {
            throw WriteError.storeFailure((error as NSError).localizedDescription)
        }
        return info
    }

    public func seriesOccurrences(id: String, in window: DateInterval) -> [Date] {
        // Occurrences of a recurring series share the same eventIdentifier;
        // EventKit's predicate expands the rule and already drops cancelled
        // occurrences (EXDATE). Filter to this series and de-dupe by second.
        guard !id.isEmpty, window.duration > 0,
              let anchor = store.event(withIdentifier: id),
              anchor.hasRecurrenceRules else { return [] } // non-recurring → no series occurrences
        let scope = anchor.calendar.map { [$0] }
        var seen = Set<Int>()
        var dates: [Date] = []
        for chunk in Self.chunk(window) {
            let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: scope)
            for ev in store.events(matching: predicate) where ev.eventIdentifier == id {
                guard let s = ev.startDate else { continue }
                if seen.insert(Int(s.timeIntervalSinceReferenceDate.rounded())).inserted { dates.append(s) }
            }
        }
        return dates
    }

    public func cancelOccurrence(id: String, occurrence: Date) throws {
        guard !id.isEmpty, let anchor = store.event(withIdentifier: id) else { return }
        guard anchor.calendar?.allowsContentModifications ?? false else { throw WriteError.notWritable }
        // Locate the specific occurrence in a tight window, then remove it with
        // .thisEvent — EventKit records the exception on the series.
        let predicate = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-1),
            end: occurrence.addingTimeInterval(1),
            calendars: anchor.calendar.map { [$0] }
        )
        let target = occurrence.timeIntervalSinceReferenceDate
        guard let occ = store.events(matching: predicate).first(where: {
            $0.eventIdentifier == id
                && abs(($0.startDate ?? .distantPast).timeIntervalSinceReferenceDate - target) < 1
        }) else { return }
        do {
            try store.remove(occ, span: .thisEvent, commit: true)
        } catch {
            throw WriteError.storeFailure((error as NSError).localizedDescription)
        }
    }

    /// Resolve a selector to exactly one writable calendar, or the default
    /// new-event calendar when no selector was given. Never silently falls back
    /// to the default when a selector was provided but unmatched.
    private func resolveWritableCalendar(_ selector: String?) throws -> EKCalendar {
        guard let selector, !selector.isEmpty else {
            guard let def = store.defaultCalendarForNewEvents else { throw WriteError.noWritableCalendar }
            guard def.allowsContentModifications else { throw WriteError.notWritable }
            return def
        }
        let matches = matchCalendars([selector])
        guard !matches.isEmpty else { throw WriteError.calendarNotFound(selector) }
        guard matches.count == 1 else { throw WriteError.ambiguousCalendar(selector) }
        guard matches[0].allowsContentModifications else { throw WriteError.notWritable }
        return matches[0]
    }

    static func ekSpan(_ s: WriteSpan) -> EKSpan {
        switch s {
        case .thisEvent: return .thisEvent
        case .futureEvents: return .futureEvents
        }
    }

    public static func availabilityValue(_ s: String) -> EKEventAvailability {
        switch s {
        case "free": return .free
        case "tentative": return .tentative
        case "unavailable": return .unavailable
        default: return .busy
        }
    }

    /// Calendars whose title or identifier matches any selector (case-insensitive).
    private func matchCalendars(_ selectors: [String]) -> [EKCalendar] {
        store.calendars(for: .event).filter { cal in
            selectors.contains { sel in
                cal.title.localizedCaseInsensitiveCompare(sel) == .orderedSame
                    || cal.calendarIdentifier.caseInsensitiveCompare(sel) == .orderedSame
            }
        }
    }

    /// Split a wide interval into <=~1400-day chunks to stay under the predicate's
    /// ~4-year span limit. `public` so the check suite can exercise the boundary
    /// arithmetic without a live EventKit store.
    public static func chunk(_ range: DateInterval) -> [DateInterval] {
        let maxSpan: TimeInterval = 1400 * 24 * 60 * 60
        guard range.duration > maxSpan else { return [range] }
        var chunks: [DateInterval] = []
        var cursor = range.start
        while cursor < range.end {
            let next = min(cursor.addingTimeInterval(maxSpan), range.end)
            chunks.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return chunks
    }

    // MARK: - EKEvent → EventInfo

    static func eventInfo(_ ev: EKEvent) -> EventInfo {
        // startDate/endDate are implicitly-unwrapped in the EK headers; coalesce
        // defensively rather than force-unwrap, so malformed data can't crash us.
        let start = ev.startDate ?? Date(timeIntervalSinceReferenceDate: 0)
        return EventInfo(
            id: ev.eventIdentifier ?? "",
            calendar: ev.calendar?.title ?? "",
            calendarId: ev.calendar?.calendarIdentifier ?? "",
            title: ev.title ?? "",
            start: start,
            end: ev.endDate ?? start,
            allDay: ev.isAllDay,
            timeZone: ev.timeZone?.identifier ?? "",
            location: ev.location ?? "",
            notes: ev.notes ?? "",
            url: ev.url?.absoluteString ?? "",
            status: statusString(ev.status),
            availability: availabilityString(ev.availability),
            organizer: participantName(ev.organizer),
            attendees: (ev.attendees ?? []).map(attendeeInfo),
            recurring: ev.hasRecurrenceRules,
            recurrenceRule: recurrenceRule(from: ev.recurrenceRules?.first)
        )
    }

    // MARK: - Recurrence ↔ RecurrenceRule

    static func recurrenceRule(from rule: EKRecurrenceRule?) -> RecurrenceRule? {
        guard let rule else { return nil }
        let freq: RecurrenceRule.Frequency
        switch rule.frequency {
        case .daily: freq = .daily
        case .weekly: freq = .weekly
        case .monthly: freq = .monthly
        case .yearly: freq = .yearly
        @unknown default: return nil // an unrecognized frequency → treat as non-recurring
        }
        let end = rule.recurrenceEnd
        let count = (end?.occurrenceCount ?? 0) > 0 ? end?.occurrenceCount : nil
        let days = (rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue }
        return RecurrenceRule(frequency: freq, interval: rule.interval, until: end?.endDate, count: count, daysOfWeek: days)
    }

    static func ekRecurrenceRule(_ rule: RecurrenceRule) -> EKRecurrenceRule {
        let freq: EKRecurrenceFrequency
        switch rule.frequency {
        case .daily: freq = .daily
        case .weekly: freq = .weekly
        case .monthly: freq = .monthly
        case .yearly: freq = .yearly
        }
        let days = rule.daysOfWeek.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        let end: EKRecurrenceEnd?
        if let until = rule.until {
            end = EKRecurrenceEnd(end: until)
        } else if let count = rule.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else {
            end = nil
        }
        return EKRecurrenceRule(
            recurrenceWith: freq, interval: rule.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil, end: end
        )
    }

    static func attendeeInfo(_ p: EKParticipant) -> AttendeeInfo {
        AttendeeInfo(
            name: p.name ?? "",
            email: email(of: p),
            status: participantStatusString(p.participantStatus),
            role: participantRoleString(p.participantRole)
        )
    }

    /// Display name, else email, else "". Used for the organizer slot.
    static func participantName(_ p: EKParticipant?) -> String {
        guard let p else { return "" }
        if let name = p.name, !name.isEmpty { return name }
        return email(of: p)
    }

    /// EKParticipant has no email property; parse it from the `mailto:` URL.
    static func email(of p: EKParticipant) -> String {
        parseMailto(p.url.absoluteString)
    }

    /// Extract the address from a `mailto:` URL string: drop the scheme, drop any
    /// `?subject=…` query, and percent-decode. "" for a non-mailto URL. `public`
    /// and pure so it's unit-testable without an EKParticipant.
    public static func parseMailto(_ urlString: String) -> String {
        let scheme = "mailto:"
        guard urlString.lowercased().hasPrefix(scheme) else { return "" }
        let rest = urlString.dropFirst(scheme.count)
        let addr = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return addr.removingPercentEncoding ?? addr
    }

    // MARK: - EK enum → string mappers

    static func typeString(_ t: EKCalendarType) -> String {
        switch t {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    static func sourceTypeString(_ t: EKSourceType?) -> String {
        switch t {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        case .none: return ""
        @unknown default: return "unknown"
        }
    }

    static func statusString(_ s: EKEventStatus) -> String {
        switch s {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    public static func availabilityString(_ a: EKEventAvailability) -> String {
        switch a {
        case .notSupported: return "notSupported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }

    static func participantStatusString(_ s: EKParticipantStatus) -> String {
        switch s {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "inProcess"
        @unknown default: return "unknown"
        }
    }

    static func participantRoleString(_ r: EKParticipantRole) -> String {
        switch r {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        @unknown default: return "unknown"
        }
    }

    static func hexColor(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
