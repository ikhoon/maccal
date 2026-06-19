// CalendarStore.swift — the testability seam.
//
// Every command depends on this protocol, never on EKEventStore directly, so
// tests drive commands against an in-memory FakeCalendarStore (no TCC, no real
// calendar, no network). The real implementation is EKCalendarStore.

import Foundation

/// A calendar the tool can see, used as a `--calendar` selector target.
public struct CalendarInfo: Codable, Sendable, Equatable {
    public let title: String
    /// Account / source title (e.g. a Google address).
    public let source: String
    /// EKCalendarType: local | caldav | exchange | subscription | birthday.
    public let type: String
    /// EKSourceType: local | caldav | exchange | mobileme | subscribed | birthdays.
    public let sourceType: String
    public let writable: Bool
    /// `#RRGGBB`, or "" when unavailable.
    public let color: String
    public let calendarIdentifier: String

    public init(
        title: String,
        source: String,
        type: String,
        sourceType: String,
        writable: Bool,
        color: String,
        calendarIdentifier: String
    ) {
        self.title = title
        self.source = source
        self.type = type
        self.sourceType = sourceType
        self.writable = writable
        self.color = color
        self.calendarIdentifier = calendarIdentifier
    }
}

/// A participant on an event (attendee or organizer detail).
public struct AttendeeInfo: Codable, Sendable, Equatable {
    public let name: String
    /// Parsed from the participant's `mailto:` URL, or "" when absent.
    public let email: String
    /// EKParticipantStatus: unknown | pending | accepted | declined | tentative
    /// | delegated | completed | inProcess.
    public let status: String
    /// EKParticipantRole: unknown | required | optional | chair | nonParticipant.
    public let role: String

    public init(name: String, email: String, status: String, role: String) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
    }
}

/// One event occurrence. Recurring series are expanded to one EventInfo per
/// occurrence; every occurrence shares `id` and differs by `start`.
///
/// Every field is always present — EventKit nils map to ""/[]/false — so JSON
/// consumers never branch on a missing key. `start`/`end` are stored as `Date`
/// (not pre-rendered strings) so the shared Output.jsonEncoder emits UTC-Z; the
/// `allDay` flag tells text consumers to render date-only.
public struct EventInfo: Codable, Sendable, Equatable {
    /// EKEvent.eventIdentifier (the series key for recurring events), or "".
    public let id: String
    /// Owning calendar title (a `--calendar` selector value).
    public let calendar: String
    /// Owning calendar identifier — joins back to `calendars --json`.
    public let calendarId: String
    public let title: String
    public let start: Date
    /// Exclusive end. For all-day events this is midnight of the day after the
    /// last day — kept verbatim (not decremented).
    public let end: Date
    public let allDay: Bool
    /// IANA zone id of the authoring zone, or "" when floating/all-day/zoneless.
    public let timeZone: String
    public let location: String
    public let notes: String
    public let url: String
    /// none | confirmed | tentative | canceled.
    public let status: String
    /// notSupported | busy | free | tentative | unavailable.
    public let availability: String
    /// Organizer display name, else its email, else "".
    public let organizer: String
    public let attendees: [AttendeeInfo]
    /// True when the event belongs to a recurring series.
    public let recurring: Bool

    public init(
        id: String,
        calendar: String,
        calendarId: String,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        timeZone: String,
        location: String,
        notes: String,
        url: String,
        status: String,
        availability: String,
        organizer: String,
        attendees: [AttendeeInfo],
        recurring: Bool
    ) {
        self.id = id
        self.calendar = calendar
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZone = timeZone
        self.location = location
        self.notes = notes
        self.url = url
        self.status = status
        self.availability = availability
        self.organizer = organizer
        self.attendees = attendees
        self.recurring = recurring
    }
}

extension EventInfo {
    /// True when the event's [start, end) overlaps the half-open `range`. This is
    /// the in-memory equivalent of what EKEventStore's predicate does, so
    /// FakeCalendarStore and the real store agree on window membership. A
    /// zero-duration (instant) event follows the same half-open rule: included at
    /// the window start, excluded at the window end.
    public func overlaps(_ range: DateInterval) -> Bool {
        if start == end { return start >= range.start && start < range.end }
        return start < range.end && end > range.start
    }

    /// True when any selector matches the event's calendar title or identifier
    /// (case-insensitive). Mirrors the `--calendar` resolution in EKCalendarStore.
    public func matchesCalendar(_ selectors: [String]) -> Bool {
        selectors.contains { sel in
            calendar.localizedCaseInsensitiveCompare(sel) == .orderedSame
                || calendarId.caseInsensitiveCompare(sel) == .orderedSame
        }
    }

    /// Canonical ordering — start ascending, then title (case-insensitive), then
    /// id — so NDJSON output is byte-stable across runs and stores.
    public static func sortedByStart(_ events: [EventInfo]) -> [EventInfo] {
        events.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let byTitle = a.title.localizedCaseInsensitiveCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return a.id < b.id
        }
    }

    /// De-duplicate occurrences by the composite (id, start) key. Recurring
    /// occurrences share an id but differ by start; abutting fetch chunks and
    /// multi-calendar membership can list the same occurrence twice. Events with
    /// an empty id are never collapsed together. Preserves first-seen order.
    public static func deduped(_ events: [EventInfo]) -> [EventInfo] {
        var seen = Set<String>()
        var result: [EventInfo] = []
        for (i, e) in events.enumerated() {
            let key = e.id.isEmpty
                ? "\u{0}\(i)"
                : "\(e.id)\u{0}\(e.start.timeIntervalSinceReferenceDate)"
            if seen.insert(key).inserted { result.append(e) }
        }
        return result
    }

    /// Return a copy with the non-nil fields of `changes` applied. nil leaves a
    /// field untouched; an empty string clears location/notes/url; an all-day
    /// result floats the zone. Used by runEdit's preview and FakeCalendarStore,
    /// mirroring EKCalendarStore.updateEvent so the fake matches the real store.
    public func applying(_ c: EventChanges) -> EventInfo {
        let resultAllDay = c.allDay ?? allDay
        return EventInfo(
            id: id, calendar: calendar, calendarId: calendarId,
            title: c.title ?? title,
            start: c.start ?? start,
            end: c.end ?? end,
            allDay: resultAllDay,
            timeZone: resultAllDay ? "" : (c.timeZoneId ?? timeZone),
            location: c.location ?? location,
            notes: c.notes ?? notes,
            url: c.url ?? url,
            status: status,
            availability: c.availability ?? availability,
            organizer: organizer, attendees: attendees, recurring: recurring
        )
    }
}

/// Which occurrences a write touches. Maps to EKSpan; for non-recurring events
/// both behave identically (the single event).
public enum WriteSpan: Sendable, Equatable {
    case thisEvent      // the resolved (anchor) occurrence only
    case futureEvents   // this occurrence and all later ones
}

/// A fully-resolved new event for `createEvent`. start/end are absolute instants
/// already computed in the authoring zone; for all-day they are local midnights
/// (end is the exclusive next-midnight, matching EventInfo.end).
public struct EventDraft: Codable, Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    /// Calendar selector (title or identifier); nil → the default new-event calendar.
    public let calendar: String?
    /// Authoring zone IANA id for timed events; nil → floating/current. Ignored for all-day.
    public let timeZoneId: String?
    public let location: String
    public let notes: String
    public let url: String
    /// busy | free | tentative | unavailable.
    public let availability: String

    public init(
        title: String, start: Date, end: Date, allDay: Bool = false,
        calendar: String? = nil, timeZoneId: String? = nil,
        location: String = "", notes: String = "", url: String = "", availability: String = "busy"
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.timeZoneId = timeZoneId
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
    }
}

/// A sparse patch for `updateEvent`: nil leaves a field untouched; for
/// location/notes/url an empty string clears the field. start/end are the
/// already-resolved instants (runEdit owns the keep-duration / duration math).
public struct EventChanges: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var allDay: Bool?
    public var timeZoneId: String?
    public var location: String?
    public var notes: String?
    public var url: String?
    public var availability: String?

    public init(
        title: String? = nil, start: Date? = nil, end: Date? = nil, allDay: Bool? = nil,
        timeZoneId: String? = nil, location: String? = nil, notes: String? = nil,
        url: String? = nil, availability: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZoneId = timeZoneId
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
    }

    /// True when no field is set — the command layer maps this to "no changes".
    public var isEmpty: Bool {
        title == nil && start == nil && end == nil && allDay == nil && timeZoneId == nil
            && location == nil && notes == nil && url == nil && availability == nil
    }
}

/// The calendar backend. Grows one method per milestone.
public protocol CalendarStore {
    func calendars() -> [CalendarInfo]
    /// Events whose [start, end) overlaps `range`, across `calendars` (matched by
    /// title or identifier, case-insensitive; nil/empty = all). Returns deduped,
    /// canonically sorted occurrences; an empty/zero-length range yields [].
    func events(in range: DateInterval, calendars: [String]?) -> [EventInfo]
    /// One event by its identifier (the `id` field of an EventInfo). For a
    /// recurring series this resolves the series, not a specific occurrence.
    /// Returns nil when no event matches.
    func event(id: String) -> EventInfo?

    /// Create a new non-recurring event; returns the persisted EventInfo (with
    /// its assigned id). Throws WriteError on calendar resolution / store failure.
    func createEvent(_ draft: EventDraft) throws -> EventInfo
    /// Apply a sparse patch to the event with `id`; returns the updated
    /// EventInfo. Throws WriteError.notFound / .notWritable / .storeFailure.
    func updateEvent(id: String, _ changes: EventChanges, span: WriteSpan) throws -> EventInfo
    /// Delete the event with `id`; returns the EventInfo as it was before
    /// removal. Throws WriteError.notFound / .notWritable / .storeFailure.
    func deleteEvent(id: String, span: WriteSpan) throws -> EventInfo
    /// The default calendar for new events, or nil when none is configured.
    func defaultWritableCalendar() -> CalendarInfo?
}
