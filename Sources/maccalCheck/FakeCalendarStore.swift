// FakeCalendarStore — in-memory CalendarStore for checks. No TCC, no EventKit.

import Foundation
import maccalCore

final class FakeCalendarStore: CalendarStore {
    var calendarList: [CalendarInfo]
    var eventList: [EventInfo]
    var defaultCalendar: CalendarInfo?
    /// Records the WriteSpan of the last update/delete, so tests can assert
    /// --all-occurrences routing without a real recurring event.
    private(set) var lastSpan: WriteSpan?
    private var idCounter = 0
    /// Test hook: occurrence start-dates per series id, standing in for EventKit's
    /// rule expansion. `seriesOccurrences` reads it; `cancelOccurrence` removes from it.
    var seriesOccurrenceDates: [String: [Date]] = [:]

    init(calendars: [CalendarInfo] = [], events: [EventInfo] = [], defaultCalendar: CalendarInfo? = nil) {
        self.calendarList = calendars
        self.eventList = events
        self.defaultCalendar = defaultCalendar
    }

    func calendars() -> [CalendarInfo] {
        calendarList
    }

    // Mirrors EKCalendarStore's full pipeline: filter by window overlap and
    // (optional) calendar selectors, de-dupe on (id, start), then return
    // canonically sorted occurrences. Running deduped() here too — even though
    // fixtures rarely duplicate — keeps the documented store contract identical
    // to the real store via the shared helpers.
    func events(in range: DateInterval, calendars: [String]?) -> [EventInfo] {
        guard range.duration > 0 else { return [] }
        var evs = eventList.filter { $0.overlaps(range) }
        if let selectors = calendars, !selectors.isEmpty {
            evs = evs.filter { $0.matchesCalendar(selectors) }
        }
        return EventInfo.sortedByStart(EventInfo.deduped(evs))
    }

    func event(id: String) -> EventInfo? {
        id.isEmpty ? nil : eventList.first { $0.id == id }
    }

    func defaultWritableCalendar() -> CalendarInfo? { defaultCalendar }

    func seriesOccurrences(id: String, in window: DateInterval) -> [Date] {
        // Half-open [start, end): exclude an occurrence exactly at window.end,
        // matching EventInfo.overlaps and EventKit's predicate.
        (seriesOccurrenceDates[id] ?? []).filter { $0 >= window.start && $0 < window.end }
    }

    func cancelOccurrence(id: String, occurrence: Date) throws {
        guard var dates = seriesOccurrenceDates[id] else { return }
        let target = Int(occurrence.timeIntervalSinceReferenceDate.rounded())
        dates.removeAll { Int($0.timeIntervalSinceReferenceDate.rounded()) == target }
        seriesOccurrenceDates[id] = dates
    }

    func createEvent(_ draft: EventDraft) throws -> EventInfo {
        let cal = try resolveCalendar(draft.calendar)
        idCounter += 1
        let info = EventInfo(
            id: "fake-\(idCounter)", calendar: cal.title, calendarId: cal.calendarIdentifier,
            title: draft.title, start: draft.start, end: draft.end, allDay: draft.allDay,
            timeZone: draft.allDay ? "" : (draft.timeZoneId ?? ""),
            location: draft.location, notes: draft.notes, url: draft.url,
            status: "confirmed", availability: draft.availability,
            organizer: "", attendees: [], recurring: draft.recurrenceRule != nil,
            recurrenceRule: draft.recurrenceRule
        )
        eventList.append(info)
        return info
    }

    func updateEvent(id: String, _ changes: EventChanges, span: WriteSpan) throws -> EventInfo {
        guard let idx = eventList.firstIndex(where: { $0.id == id }) else { throw WriteError.notFound(id) }
        try ensureWritable(eventList[idx])
        lastSpan = span
        var updated = eventList[idx].applying(changes)
        // Move to another calendar when requested (validates existence + writable).
        if let sel = changes.calendar {
            let target = try resolveCalendar(sel)
            updated = updated.movingTo(calendar: target.title, calendarId: target.calendarIdentifier)
        }
        eventList[idx] = updated
        return updated
    }

    func updateOccurrence(id: String, occurrence: Date, _ changes: EventChanges) throws -> EventInfo {
        guard let series = eventList.first(where: { $0.id == id }), series.recurring else { throw WriteError.notFound(id) }
        try ensureWritable(series)
        // The occurrence must actually exist — EK locates it by date; match that so
        // a bogus occurrence doesn't silently "succeed" in the fake.
        let target = occurrence.timeIntervalSinceReferenceDate
        guard (seriesOccurrenceDates[id] ?? []).contains(where: { abs($0.timeIntervalSinceReferenceDate - target) < 1 }) else {
            throw WriteError.notFound(id)
        }
        lastSpan = .thisEvent
        // A detached occurrence at `occurrence`, with the (non-schedule) changes applied.
        return series.detachedOccurrence(at: occurrence).applying(changes)
    }

    func deleteEvent(id: String, span: WriteSpan) throws -> EventInfo {
        guard let idx = eventList.firstIndex(where: { $0.id == id }) else { throw WriteError.notFound(id) }
        try ensureWritable(eventList[idx])
        lastSpan = span
        return eventList.remove(at: idx)
    }

    // Mirrors EKCalendarStore.resolveWritableCalendar over the in-memory list.
    private func resolveCalendar(_ selector: String?) throws -> CalendarInfo {
        guard let selector, !selector.isEmpty else {
            guard let def = defaultCalendar else { throw WriteError.noWritableCalendar }
            guard def.writable else { throw WriteError.notWritable }
            return def
        }
        let matches = calendarList.filter {
            $0.title.localizedCaseInsensitiveCompare(selector) == .orderedSame
                || $0.calendarIdentifier.caseInsensitiveCompare(selector) == .orderedSame
        }
        guard !matches.isEmpty else { throw WriteError.calendarNotFound(selector) }
        guard matches.count == 1 else { throw WriteError.ambiguousCalendar(selector) }
        guard matches[0].writable else { throw WriteError.notWritable }
        return matches[0]
    }

    // A read-only calendar in calendarList blocks update/delete of its events.
    private func ensureWritable(_ e: EventInfo) throws {
        if let cal = calendarList.first(where: { $0.title == e.calendar || $0.calendarIdentifier == e.calendarId }),
           !cal.writable {
            throw WriteError.notWritable
        }
    }
}

extension CalendarInfo {
    static func fixture(
        title: String,
        source: String = "iCloud",
        type: String = "caldav",
        sourceType: String = "caldav",
        writable: Bool = true,
        color: String = "#FF0000",
        calendarIdentifier: String = "id"
    ) -> CalendarInfo {
        CalendarInfo(
            title: title, source: source, type: type, sourceType: sourceType,
            writable: writable, color: color, calendarIdentifier: calendarIdentifier
        )
    }
}

extension EventInfo {
    static func fixture(
        id: String = "id",
        title: String = "Event",
        calendar: String = "Work",
        calendarId: String = "cal-id",
        start: Date,
        end: Date,
        allDay: Bool = false,
        timeZone: String = "",
        location: String = "",
        notes: String = "",
        url: String = "",
        status: String = "confirmed",
        availability: String = "busy",
        organizer: String = "",
        attendees: [AttendeeInfo] = [],
        recurring: Bool = false,
        recurrenceRule: RecurrenceRule? = nil
    ) -> EventInfo {
        EventInfo(
            id: id, calendar: calendar, calendarId: calendarId, title: title,
            start: start, end: end, allDay: allDay, timeZone: timeZone,
            location: location, notes: notes, url: url, status: status,
            availability: availability, organizer: organizer,
            attendees: attendees, recurring: recurring,
            recurrenceRule: recurrenceRule
        )
    }
}
