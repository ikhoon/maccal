// Integration.swift — live EventKit round-trip checks (LOCAL-ONLY).
//
// Everything else in maccalCheck is pure (FakeCalendarStore: no TCC, no real
// calendar) and runs in CI. These checks instead drive the real EKCalendarStore:
// they create a throwaway local calendar, run create → fetch → update → delete
// through it, then remove the calendar — so the user's real events are never
// touched. They need a Calendar (TCC) grant, so they are gated behind
// `--integration` and skipped (not failed) when access isn't available.

import EventKit
import Foundation
import maccalCore

func runIntegrationChecks(_ c: Check) async {
    let ek = EKEventStore()

    let granted: Bool
    do {
        granted = try await ek.requestFullAccessToEvents()
    } catch {
        granted = false
    }
    guard granted else {
        FileHandle.standardError.write(Data(
            "integration: SKIPPED — no Calendar access. Grant it (`maccal auth`, or allow your terminal in System Settings → Privacy → Calendars) and retry.\n".utf8))
        return
    }

    // A throwaway local calendar, so the round-trip never touches real events.
    guard let source = ek.sources.first(where: { $0.sourceType == .local })
        ?? ek.defaultCalendarForNewEvents?.source else {
        FileHandle.standardError.write(Data(
            "integration: SKIPPED — no writable calendar source available.\n".utf8))
        return
    }

    let cal = EKCalendar(for: .event, eventStore: ek)
    cal.title = "maccal-itest"
    cal.source = source
    do {
        try ek.saveCalendar(cal, commit: true)
    } catch {
        c.expect(false, "integration: could not create a temp calendar: \(error.localizedDescription)")
        return
    }
    // Always remove the throwaway calendar, even if a check throws.
    defer { try? ek.removeCalendar(cal, commit: true) }

    let store = EKCalendarStore(store: ek)
    let calId = cal.calendarIdentifier
    let start = Date().addingTimeInterval(3600)
    let end = start.addingTimeInterval(3600)
    let win = DateInterval(start: start.addingTimeInterval(-300), end: end.addingTimeInterval(300))

    do {
        // create
        let created = try store.createEvent(
            EventDraft(title: "maccal-itest-event", start: start, end: end, calendar: calId))
        c.expect(!created.id.isEmpty, "integration: createEvent assigns a non-empty id")
        c.eq(created.calendar, "maccal-itest", "integration: created event lands in the temp calendar")

        // fetch
        let fetched = store.events(in: win, calendars: [calId])
        c.eq(fetched.count, 1, "integration: created event is fetched back from the live store")
        c.eq(fetched.first?.title, "maccal-itest-event", "integration: fetched title round-trips")

        // update
        let updated = try store.updateEvent(
            id: created.id, EventChanges(title: "maccal-itest-renamed"), span: .thisEvent)
        c.eq(updated.title, "maccal-itest-renamed", "integration: updateEvent returns the new title")
        c.eq(store.event(id: created.id)?.title, "maccal-itest-renamed", "integration: update persisted in the live store")

        // delete
        _ = try store.deleteEvent(id: created.id, span: .thisEvent)
        c.expect(store.event(id: created.id) == nil, "integration: deleteEvent removes the event")
        c.eq(store.events(in: win, calendars: [calId]).count, 0, "integration: no events remain after delete")
    } catch {
        c.expect(false, "integration: live CRUD threw: \(error)")
    }
}
