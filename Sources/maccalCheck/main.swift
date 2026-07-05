// main.swift — maccal check suite. Run with `swift run maccalCheck`.
//
// Drives pure logic and command run* functions against FakeCalendarStore, so
// no TCC grant, no real calendar, and no network are ever needed.

import Foundation
import maccalCore

let c = Check()

// MARK: Output

c.eq(Output.tsv([["a", "b"], ["c", "d"]]), "a\tb\nc\td\n", "tsv joins tabs + newline")
c.eq(Output.tsv([]), "", "tsv empty → empty")

let stamp = Date(timeIntervalSince1970: 1_780_367_700) // 2026-06-02T02:35:00Z
let kst = TimeZone(identifier: "Asia/Seoul")!
c.eq(Output.localISO(stamp, timeZone: kst), "2026-06-02T11:35:00+09:00", "localISO has offset")
c.eq(Output.localDate(stamp, timeZone: kst), "2026-06-02", "localDate is date-only")

struct WhenRow: Encodable { let when: Date }
let ndjson = Output.ndjson([WhenRow(when: stamp)])
c.expect(ndjson.contains("2026-06-02T02:35:00Z"), "ndjson dates are UTC Z: \(ndjson)")
c.expect(ndjson.hasSuffix("\n"), "ndjson ends with newline")

// MARK: calendars

let store = FakeCalendarStore(calendars: [
    .fixture(title: "Work", source: "corp@example.com", writable: true),
    .fixture(title: "Personal", source: "me@gmail.com", writable: true),
    .fixture(title: "Holidays", source: "Subscriptions", type: "subscription", writable: false),
])

do {
    let lines = runCalendars(store: store, json: false).split(separator: "\n").map(String.init)
    c.eq(lines.count, 3, "calendars text: 3 rows")
    // Sorted by (source, title): corp@ < me@gmail < Subscriptions.
    c.expect(lines[0].hasPrefix("Work\tcorp@example.com\t"), "sorted row 0")
    c.expect(lines[1].hasPrefix("Personal\tme@gmail.com\t"), "sorted row 1")
    c.expect(lines[2].hasPrefix("Holidays\tSubscriptions\t"), "sorted row 2")
    // rw/ro is now the last column (the color swatch/hex column was dropped from
    // text output; color, when on, is a leading dot only).
    c.expect(lines[0].hasSuffix("\trw"), "writable column rw (last col)")
    c.expect(lines[2].hasSuffix("\tro"), "read-only column ro (last col)")
}

do {
    let out = runCalendars(store: store, json: false, writableOnly: true)
    c.expect(!out.contains("Holidays"), "writableOnly hides read-only")
    c.expect(out.contains("Work"), "writableOnly keeps writable")
}

do {
    let lines = runCalendars(store: store, json: false, sourceFilter: "GMAIL").split(separator: "\n")
    c.eq(lines.count, 1, "sourceFilter is case-insensitive substring")
}

do {
    let lines = runCalendars(store: store, json: true).split(separator: "\n").map(String.init)
    c.eq(lines.count, 3, "calendars json: 3 lines")
    for line in lines {
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        c.expect(obj != nil, "each json line is an object: \(line)")
    }
}

c.eq(runCalendars(store: FakeCalendarStore(), json: false), "", "empty store text → empty")
c.eq(runCalendars(store: FakeCalendarStore(), json: true), "", "empty store json → empty")

// MARK: events — EventInfo + CalendarStore.events(in:calendars:)

let t0 = Date(timeIntervalSince1970: 1_780_000_000)
let hour: TimeInterval = 3600
let day: TimeInterval = 86_400
let at: (TimeInterval) -> Date = { t0.addingTimeInterval($0) }
let win = DateInterval(start: t0, end: at(10 * day))

let evStore = FakeCalendarStore(events: [
    .fixture(id: "b", title: "Lunch", calendar: "Work", start: at(3 * hour), end: at(4 * hour)),
    .fixture(id: "a", title: "Standup", calendar: "Work", start: at(1 * hour), end: at(2 * hour)),
    .fixture(id: "c", title: "Review", calendar: "Personal", calendarId: "cal-personal", start: at(5 * hour), end: at(6 * hour)),
])

do {
    let evs = evStore.events(in: win, calendars: nil)
    c.eq(evs.count, 3, "events(nil): all in window")
    c.eq(evs.map { $0.id }, ["a", "b", "c"], "events sorted by (start, title, id)")
}

do {
    let work = evStore.events(in: win, calendars: ["work"])
    c.eq(work.count, 2, "calendar filter is case-insensitive by title")
    c.expect(work.allSatisfy { $0.calendar == "Work" }, "filter keeps only Work")
    c.eq(evStore.events(in: win, calendars: ["cal-personal"]).count, 1, "filter matches by calendarIdentifier")
    c.eq(evStore.events(in: win, calendars: ["nope"]).count, 0, "non-matching selector → none")
}

do {
    // Half-open window: start-boundary included, end-boundary excluded.
    let boundary = FakeCalendarStore(events: [
        .fixture(id: "atStart", title: "AtStart", start: t0, end: at(hour)),
        .fixture(id: "atEnd", title: "AtEnd", start: at(10 * day), end: at(10 * day + hour)),
    ])
    let bevs = boundary.events(in: win, calendars: nil)
    c.expect(bevs.contains { $0.id == "atStart" }, "event at window start included")
    c.expect(!bevs.contains { $0.id == "atEnd" }, "event at window end excluded (half-open)")
}

do {
    let zero = DateInterval(start: t0, end: t0)
    c.eq(evStore.events(in: zero, calendars: nil).count, 0, "zero-length window → empty")
    c.eq(Output.ndjson(evStore.events(in: zero, calendars: nil)), "", "empty events → empty ndjson")
}

do {
    // (id, start) dedupe: same id + different start are distinct occurrences;
    // identical (id, start) collapses; empty ids never collapse together.
    let occ1 = EventInfo.fixture(id: "r", title: "Daily", start: at(hour), end: at(2 * hour))
    let occ2 = EventInfo.fixture(id: "r", title: "Daily", start: at(day + hour), end: at(day + 2 * hour))
    let occ1Dup = EventInfo.fixture(id: "r", title: "Daily", start: at(hour), end: at(2 * hour))
    c.eq(EventInfo.deduped([occ1, occ2, occ1Dup]).count, 2, "dedupe collapses identical (id,start), keeps distinct occurrences")
    let blank1 = EventInfo.fixture(id: "", title: "A", start: at(hour), end: at(2 * hour))
    let blank2 = EventInfo.fixture(id: "", title: "B", start: at(hour), end: at(2 * hour))
    c.eq(EventInfo.deduped([blank1, blank2]).count, 2, "empty ids are keyed by position, never collapsed")
    let mixed = EventInfo.deduped([
        EventInfo.fixture(id: "", title: "X", start: at(hour), end: at(2 * hour)),
        EventInfo.fixture(id: "k", title: "Y", start: at(hour), end: at(2 * hour)),
        EventInfo.fixture(id: "", title: "Z", start: at(hour), end: at(2 * hour)),
    ])
    c.eq(mixed.map { $0.title }, ["X", "Y", "Z"], "mixed empty/non-empty ids all survive in first-seen order")
}

do {
    let evStamp = Date(timeIntervalSince1970: 1_780_367_700) // 2026-06-02T02:35:00Z
    let timed = EventInfo.fixture(id: "s", title: "X", start: evStamp, end: evStamp.addingTimeInterval(hour))
    c.expect(Output.ndjson([timed]).contains("2026-06-02T02:35:00Z"), "event start encodes UTC-Z")

    let allDay = EventInfo.fixture(id: "ad", title: "Holiday", start: at(0), end: at(day), allDay: true)
    let adLine = Output.ndjson([allDay])
    c.expect(adLine.contains("\"allDay\":true"), "allDay flag carried in json")
    c.expect(adLine.contains("\"start\":\""), "allDay event still carries a start timestamp")
}

do {
    let withAtt = EventInfo.fixture(
        id: "m", title: "Meeting", start: at(hour), end: at(2 * hour),
        attendees: [AttendeeInfo(name: "Kim", email: "kim@example.com", status: "accepted", role: "required")]
    )
    let attLine = Output.ndjson([withAtt])
    c.expect(attLine.contains("\"attendees\":[{"), "attendees serialized as array of objects")
    c.expect(attLine.contains("\"email\":\"kim@example.com\""), "attendee email present")
    let solo = Output.ndjson([EventInfo.fixture(id: "n", title: "Solo", start: at(hour), end: at(2 * hour))])
    c.expect(solo.contains("\"attendees\":[]"), "no attendees → empty array, key still present")
}

do {
    // Every key present even when source values are empty.
    let line = Output.ndjson([EventInfo.fixture(id: "k", title: "", start: at(hour), end: at(2 * hour))])
        .split(separator: "\n").first.map(String.init) ?? ""
    let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    let keys = Set((obj ?? [:]).keys)
    let expected: Set<String> = [
        "id", "calendar", "calendarId", "title", "start", "end", "allDay", "timeZone",
        "location", "notes", "url", "status", "availability", "organizer", "attendees", "recurring",
    ]
    c.eq(keys, expected, "every EventInfo key is always present")
}

// MARK: DateWindow — pure --from/--to range parsing

func throwsParsing(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

let kstNow = Date(timeIntervalSince1970: 1_780_367_700) // 2026-06-02T11:35:00+09:00
var kstCal = Calendar(identifier: .gregorian)
kstCal.timeZone = kst

do {
    let expected = kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20))!
    c.eq(try! DateWindow.parseBound("2026-06-20", now: kstNow, timeZone: kst), expected, "parseBound YYYY-MM-DD → local midnight")

    let today = try! DateWindow.parseBound("today", now: kstNow, timeZone: kst)
    let tomorrow = try! DateWindow.parseBound("tomorrow", now: kstNow, timeZone: kst)
    let yesterday = try! DateWindow.parseBound("yesterday", now: kstNow, timeZone: kst)
    c.eq(today, kstCal.startOfDay(for: kstNow), "today → start of today")
    c.eq(tomorrow, kstCal.date(byAdding: .day, value: 1, to: today)!, "tomorrow = today + 1d")
    c.eq(yesterday, kstCal.date(byAdding: .day, value: -1, to: today)!, "yesterday = today - 1d")

    c.eq(try! DateWindow.parseBound("+7d", now: kstNow, timeZone: kst), kstCal.date(byAdding: .day, value: 7, to: today)!, "+7d")
    c.eq(try! DateWindow.parseBound("+1w", now: kstNow, timeZone: kst), kstCal.date(byAdding: .day, value: 7, to: today)!, "+1w == +7d")
    c.eq(try! DateWindow.parseBound("-3d", now: kstNow, timeZone: kst), kstCal.date(byAdding: .day, value: -3, to: today)!, "-3d")
}

do {
    c.expect(throwsParsing { _ = try DateWindow.parseBound("2026-02-30", now: kstNow, timeZone: kst) }, "2026-02-30 → throws (impossible day)")
    c.expect(throwsParsing { _ = try DateWindow.parseBound("2026-13-01", now: kstNow, timeZone: kst) }, "2026-13-01 → throws (impossible month)")
    c.expect(throwsParsing { _ = try DateWindow.parseBound("garbage", now: kstNow, timeZone: kst) }, "garbage → throws")
    c.expect(throwsParsing { _ = try DateWindow.parseBound("2026-6-2", now: kstNow, timeZone: kst) }, "non-zero-padded → throws")
}

do {
    // natural-language dates (weekday results are asserted by weekday + direction,
    // so they don't depend on which weekday kstNow happens to be).
    func nl(_ s: String) -> Date { try! DateWindow.parseBound(s, now: kstNow, timeZone: kst) }
    let today = kstCal.startOfDay(for: kstNow)
    c.eq(nl("in 3 days"), kstCal.date(byAdding: .day, value: 3, to: today)!, "in 3 days")
    c.eq(nl("in 2 weeks"), kstCal.date(byAdding: .day, value: 14, to: today)!, "in 2 weeks")
    c.eq(nl("next week"), kstCal.date(byAdding: .day, value: 7, to: today)!, "next week = +7d")
    c.eq(nl("last week"), kstCal.date(byAdding: .day, value: -7, to: today)!, "last week = -7d")
    c.eq(kstCal.component(.weekday, from: nl("friday")), 6, "bare 'friday' resolves to a Friday")
    c.expect(nl("friday") > today, "bare weekday is upcoming (future)")
    c.eq(kstCal.component(.weekday, from: nl("Monday")), 2, "weekday is case-insensitive")
    c.expect(nl("last friday") < today && kstCal.component(.weekday, from: nl("last friday")) == 6,
             "last friday is a past Friday")
    c.expect(throwsParsing { _ = try DateWindow.parseBound("someday", now: kstNow, timeZone: kst) },
             "unknown natural-language phrase still throws")
}

do {
    let today = kstCal.startOfDay(for: kstNow)
    let agenda = try! DateWindow.window(from: nil, to: nil, now: kstNow, timeZone: kst, defaultFromDays: 0, defaultSpanDays: 7)
    c.eq(agenda.start, today, "agenda default window starts today")
    c.eq(agenda.end, kstCal.date(byAdding: .day, value: 7, to: today)!, "agenda default window ends today + 7d")
    c.eq(kstCal.dateComponents([.day], from: agenda.start, to: agenda.end).day, 7, "agenda default window spans 7 local days")

    let search = try! DateWindow.window(from: nil, to: nil, now: kstNow, timeZone: kst, defaultFromDays: -30, defaultSpanDays: 60)
    c.eq(search.start, kstCal.date(byAdding: .day, value: -30, to: today)!, "search default window starts today - 30d")
    c.eq(search.end, kstCal.date(byAdding: .day, value: 30, to: today)!, "search default window ends today + 30d")

    let zero = try! DateWindow.window(from: "2026-06-20", to: "2026-06-20", now: kstNow, timeZone: kst, defaultFromDays: 0, defaultSpanDays: 7)
    c.eq(zero.duration, 0, "to == from → zero-length window")
    let reversed = try! DateWindow.window(from: "2026-06-20", to: "2026-06-10", now: kstNow, timeZone: kst, defaultFromDays: 0, defaultSpanDays: 7)
    c.eq(reversed.duration, 0, "to < from → clamped to zero-length")
}

do {
    // DST: a window spanning the US spring-forward (2026-03-08) must still advance
    // by whole local days — both bounds at local midnight, 2 calendar days, < 48h.
    let ny = TimeZone(identifier: "America/New_York")!
    var nyCal = Calendar(identifier: .gregorian)
    nyCal.timeZone = ny
    let nyNow = nyCal.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
    let dst = try! DateWindow.window(from: "today", to: "+2d", now: nyNow, timeZone: ny, defaultFromDays: 0, defaultSpanDays: 7)
    c.eq(nyCal.startOfDay(for: dst.start), dst.start, "DST: start at local midnight")
    c.eq(nyCal.startOfDay(for: dst.end), dst.end, "DST: end at local midnight")
    c.eq(nyCal.dateComponents([.day], from: dst.start, to: dst.end).day, 2, "DST: spans 2 calendar days across spring-forward")
    c.expect(dst.duration < 2 * 86_400, "DST: 2 local days is < 48h across spring-forward")
}

// MARK: agenda — runAgenda

let agToday = kstCal.startOfDay(for: kstNow)

do {
    let evs: [EventInfo] = [
        .fixture(id: "e2", title: "Lunch", calendar: "Work", start: agToday.addingTimeInterval(2 * day + 3 * hour), end: agToday.addingTimeInterval(2 * day + 4 * hour)),
        .fixture(id: "e1", title: "Standup", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        .fixture(id: "ehol", title: "Holiday", calendar: "Work", start: agToday, end: agToday.addingTimeInterval(day), allDay: true),
        .fixture(id: "efar", title: "FarFuture", calendar: "Work", start: agToday.addingTimeInterval(30 * day), end: agToday.addingTimeInterval(30 * day + hour)),
    ]
    let lines = try! runAgenda(store: FakeCalendarStore(events: evs), json: false, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(lines.count, 3, "agenda lists the 3 events in the default 7-day window (far-future excluded)")
    c.expect(lines[0].hasSuffix("\tehol"), "all-day midnight event sorts first")
    c.expect(lines[1].hasSuffix("\te1"), "standup second")
    c.expect(lines[2].hasSuffix("\te2"), "lunch third")
    c.eq(lines[1].split(separator: "\t").count, 3, "single-calendar rows are when/title/id (no calendar column)")
    c.eq(lines[0].split(separator: "\t").map(String.init)[0], Output.localDate(agToday, timeZone: kst), "all-day when cell is a bare date")
    c.expect(lines[1].split(separator: "\t").map(String.init)[0].contains("+09:00"), "timed when cell carries the local offset")
}

do {
    let evs: [EventInfo] = [
        .fixture(id: "w", title: "WorkMtg", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        .fixture(id: "p", title: "Gym", calendar: "Personal", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour)),
    ]
    let lines = try! runAgenda(store: FakeCalendarStore(events: evs), json: false, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(lines[0].split(separator: "\t").count, 4, "multi-calendar rows insert the calendar column")
    let cols0 = lines[0].split(separator: "\t").map(String.init)
    c.expect(cols0[1] == "Work" && cols0.last == "w", "calendar is column 2 and id is last when multi-calendar")
}

do {
    let evs = (0..<5).map { i in
        EventInfo.fixture(id: "x\(i)", title: "E\(i)", calendar: "Work",
                          start: agToday.addingTimeInterval(Double(i + 1) * hour),
                          end: agToday.addingTimeInterval(Double(i + 1) * hour + 1800))
    }
    let store5 = FakeCalendarStore(events: evs)
    let capped = try! runAgenda(store: store5, json: false, max: 3, now: kstNow, timeZone: kst)
    // The truncation notice now goes to stderr; stdout stays clean, parseable rows.
    c.expect(!capped.contains("showing"), "truncation notice kept out of stdout")
    c.eq(capped.split(separator: "\n").count, 3, "--max caps shown rows")
    c.eq(try! runAgenda(store: store5, json: false, max: 10, now: kstNow, timeZone: kst).split(separator: "\n").count, 5, "all rows when total <= max")
}

do {
    let evs = [EventInfo.fixture(id: "j", title: "J", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    let j = try! runAgenda(store: FakeCalendarStore(events: evs), json: true, now: kstNow, timeZone: kst)
    c.expect(j.contains("\"id\":\"j\""), "agenda --json emits the event")
    c.expect(!j.contains("_summary"), "agenda --json has no _summary line")
    let empty = FakeCalendarStore(events: [])
    c.eq(try! runAgenda(store: empty, json: false, now: kstNow, timeZone: kst), "", "no events → empty text")
    c.eq(try! runAgenda(store: empty, json: true, now: kstNow, timeZone: kst), "", "no events → empty json")
}

do {
    let evs = [EventInfo.fixture(id: "t", title: "Multi\tLine\nTitle", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    let line = try! runAgenda(store: FakeCalendarStore(events: evs), json: false, now: kstNow, timeZone: kst)
        .split(separator: "\n").first.map(String.init) ?? ""
    c.eq(line.split(separator: "\t").count, 3, "sanitized title keeps the row at 3 columns")
    c.expect(line.contains("Multi Line Title"), "tab/newline in title collapsed to spaces")
}

// MARK: hide-cancelled — opt-in filter for cancelled events

do {
    let evs = [
        EventInfo.fixture(id: "A", title: "Live", calendar: "Work",
                          start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "B", title: "Scrapped", calendar: "Work",
                          start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour),
                          status: "canceled"),
    ]
    let s = FakeCalendarStore(events: evs)
    let hidden = try! runAgenda(store: s, json: false, hideCancelled: true, now: kstNow, timeZone: kst)
    c.expect(hidden.contains("Live") && !hidden.contains("Scrapped"), "agenda --hide-cancelled drops cancelled events")
    let shown = try! runAgenda(store: s, json: false, hideCancelled: false, now: kstNow, timeZone: kst)
    c.expect(shown.contains("Live") && shown.contains("Scrapped"), "agenda without the flag shows cancelled events")
    let searched = try! runSearch(store: s, query: "", json: false, hideCancelled: true, now: kstNow, timeZone: kst)
    c.expect(searched.contains("Live") && !searched.contains("Scrapped"), "search --hide-cancelled drops cancelled events")
    let searchedAll = try! runSearch(store: s, query: "", json: false, hideCancelled: false, now: kstNow, timeZone: kst)
    c.expect(searchedAll.contains("Live") && searchedAll.contains("Scrapped"), "search without the flag shows cancelled events")
}

// MARK: show — runShow

do {
    let ev = EventInfo.fixture(
        id: "EVT-1", title: "Team Sync", calendar: "Work",
        start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour),
        location: "Room 4F", notes: "Discuss Q3 plan.", url: "https://meet.example.com/x",
        status: "confirmed", availability: "busy", organizer: "Kim",
        attendees: [AttendeeInfo(name: "Lee", email: "lee@example.com", status: "accepted", role: "required")]
    )
    let store = FakeCalendarStore(events: [ev])

    let (jsonOut, jfound) = runShow(store: store, id: "EVT-1", json: true, timeZone: kst)
    c.expect(jfound, "show finds the event")
    c.expect(jsonOut.contains("\"id\":\"EVT-1\""), "show --json includes id")
    c.expect(jsonOut.contains("\"location\":\"Room 4F\""), "show --json includes location")
    c.eq(jsonOut.split(separator: "\n").count, 1, "show --json is a single line")

    let (textOut, tfound) = runShow(store: store, id: "EVT-1", json: false, timeZone: kst)
    c.expect(tfound, "show text finds the event")
    c.expect(textOut.contains("Title:") && textOut.contains("Team Sync"), "text block has Title")
    c.expect(textOut.contains("When:"), "text block has When")
    c.expect(textOut.contains("Calendar:") && textOut.contains("Work"), "text block has Calendar")
    c.expect(textOut.contains("Attendees:") && textOut.contains("Lee <lee@example.com> — required/accepted"), "text lists attendee as name <email> — role/status")
    c.expect(textOut.contains("Discuss Q3 plan."), "text block shows the notes body")

    let (missOut, mfound) = runShow(store: store, id: "NOPE", json: false, timeZone: kst)
    c.expect(!mfound, "unknown id → not found")
    c.eq(missOut, "", "unknown id → empty output")
    c.expect(runShow(store: store, id: "", json: false, timeZone: kst).found == false, "empty id → not found")
}

do {
    let allDay = EventInfo.fixture(id: "AD", title: "Holiday", start: agToday, end: agToday.addingTimeInterval(day), allDay: true)
    let (out, _) = runShow(store: FakeCalendarStore(events: [allDay]), id: "AD", json: false, timeZone: kst)
    c.expect(out.contains("When:") && out.contains(Output.localDate(agToday, timeZone: kst)), "all-day show When is a bare date")
    c.expect(!out.contains(" - "), "all-day show has no start-end range")

    let recurring = EventInfo.fixture(id: "R", title: "Weekly", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), recurring: true)
    let (rj, _) = runShow(store: FakeCalendarStore(events: [recurring]), id: "R", json: true, timeZone: kst)
    c.expect(rj.contains("\"recurring\":true"), "recurring event shows recurring:true in --json")
}

// MARK: search — runSearch

do {
    let evs: [EventInfo] = [
        .fixture(id: "s1", title: "Daily Standup", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), location: "Room A", notes: "sync"),
        .fixture(id: "s2", title: "Lunch", calendar: "Work", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour), location: "Cafe", notes: "standup leftovers discussion"),
        .fixture(id: "s3", title: "1:1", calendar: "Personal", start: agToday.addingTimeInterval(5 * hour), end: agToday.addingTimeInterval(6 * hour), location: "standup booth", notes: "career"),
    ]
    let store = FakeCalendarStore(events: evs)

    let allLines = try! runSearch(store: store, query: "STANDUP", json: false, scope: .all, now: kstNow, timeZone: kst)
        .split(separator: "\n").filter { !$0.hasPrefix("(showing ") }.map(String.init)
    c.eq(allLines.count, 3, "search --in all matches title/notes/location, case-insensitive")

    let titleLines = try! runSearch(store: store, query: "standup", json: false, scope: .title, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(titleLines.count, 1, "search --in title only matches the title hit")
    c.expect(titleLines[0].hasSuffix("\ts1"), "title scope returns only the standup-titled event")

    let locLines = try! runSearch(store: store, query: "standup", json: false, scope: .location, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(locLines.count, 1, "search --in location only matches the location hit")
    c.expect(locLines[0].hasSuffix("\ts3"), "location scope returns only the standup-location event")

    let noteLines = try! runSearch(store: store, query: "standup", json: false, scope: .notes, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(noteLines.count, 1, "search --in notes only matches the notes hit")
    c.expect(noteLines[0].hasSuffix("\ts2"), "notes scope returns only the standup-notes event")

    c.expect(SearchScope(rawValue: "bogus") == nil, "invalid --in value does not parse")
    c.expect(SearchScope(rawValue: "notes") == .notes, "valid --in value parses")
}

do {
    let evs = (0..<5).map { i in
        EventInfo.fixture(id: "m\(i)", title: "Meeting \(i)", calendar: "Work",
                          start: agToday.addingTimeInterval(Double(i + 1) * hour),
                          end: agToday.addingTimeInterval(Double(i + 1) * hour + 1800))
    }
    let store = FakeCalendarStore(events: evs)

    let text = try! runSearch(store: store, query: "meeting", json: false, max: 2, now: kstNow, timeZone: kst)
    // Truncation notice → stderr; stdout is just the capped rows.
    c.expect(!text.contains("showing"), "search truncation notice kept out of stdout")
    let rows = text.split(separator: "\n").map(String.init)
    c.eq(rows.count, 2, "search --max caps shown rows")
    c.expect(rows[0].hasSuffix("\tm0") && rows[1].hasSuffix("\tm1"), "search results are soonest-first")

    let jlines = try! runSearch(store: store, query: "meeting", json: true, max: 2, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(jlines.count, 3, "search --json: 2 rows + 1 summary line")
    c.expect(jlines.last!.contains("\"_summary\""), "final json line is the _summary")
    c.expect(jlines.last!.contains("\"shown\":2") && jlines.last!.contains("\"total\":5"), "summary carries shown and the true total")
    c.expect(jlines.last!.contains("\"examined\":5"), "summary reports examined (events scanned)")
}

do {
    let evs = (0..<3).map { i in
        EventInfo.fixture(id: "c\(i)", title: "Review \(i)", calendar: "Work",
                          start: agToday.addingTimeInterval(Double(i + 1) * hour),
                          end: agToday.addingTimeInterval(Double(i + 1) * hour + 1800))
    }
    let store = FakeCalendarStore(events: evs)

    let jc = try! runSearch(store: store, query: "review", json: true, countOnly: true, now: kstNow, timeZone: kst)
    c.eq(jc.split(separator: "\n").count, 1, "search --count-only --json emits only the summary line")
    c.expect(jc.contains("\"shown\":0") && jc.contains("\"total\":3"), "count-only summary: shown 0, total 3")
    let tc = try! runSearch(store: store, query: "review", json: false, countOnly: true, now: kstNow, timeZone: kst)
    c.expect(tc.contains("total: 3") && tc.contains("examined: 3"), "count-only text prints total and examined")
}

do {
    let evs = [EventInfo.fixture(id: "z", title: "Zebra", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    let store = FakeCalendarStore(events: evs)
    let j = try! runSearch(store: store, query: "nomatch", json: true, now: kstNow, timeZone: kst)
    c.eq(j.split(separator: "\n").count, 1, "no matches --json → only the summary line")
    c.expect(j.contains("\"shown\":0") && j.contains("\"total\":0"), "no matches summary: shown 0, total 0")
    c.eq(try! runSearch(store: store, query: "nomatch", json: false, now: kstNow, timeZone: kst), "", "no matches text → empty")
}

do {
    let evs = [
        EventInfo.fixture(id: "w", title: "Sync work", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "p", title: "Sync personal", calendar: "Personal", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour)),
    ]
    let lines = try! runSearch(store: FakeCalendarStore(events: evs), query: "sync", json: false, now: kstNow, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(lines[0].split(separator: "\t").count, 4, "search inserts the calendar column when matches span >1 calendar")
}

// MARK: review hardening — fixes confirmed by the M2 review

do {
    // overlaps() is half-open even for zero-duration instants.
    let zwin = DateInterval(start: t0, end: at(10 * day))
    let atStart = FakeCalendarStore(events: [.fixture(id: "zs", title: "Instant", start: t0, end: t0)])
    c.eq(atStart.events(in: zwin, calendars: nil).count, 1, "zero-duration event at window start is included")
    let atEnd = FakeCalendarStore(events: [.fixture(id: "ze", title: "Instant", start: at(10 * day), end: at(10 * day))])
    c.eq(atEnd.events(in: zwin, calendars: nil).count, 0, "zero-duration event at window end is excluded")
}

do {
    // EKCalendarStore.chunk boundary arithmetic (the ~4-year predicate workaround).
    let base = Date(timeIntervalSinceReferenceDate: 0)
    let maxSpan: TimeInterval = 1400 * 24 * 60 * 60
    c.eq(EKCalendarStore.chunk(DateInterval(start: base, end: base.addingTimeInterval(maxSpan - 1))).count, 1, "chunk: sub-maxSpan → 1 chunk")
    c.eq(EKCalendarStore.chunk(DateInterval(start: base, end: base.addingTimeInterval(maxSpan))).count, 1, "chunk: exactly maxSpan → 1 chunk")
    let wide = DateInterval(start: base, end: base.addingTimeInterval(maxSpan + 86_400))
    let chunks = EKCalendarStore.chunk(wide)
    c.eq(chunks.count, 2, "chunk: > maxSpan → 2 chunks")
    c.eq(chunks.first!.start, wide.start, "chunk: first chunk starts at range start")
    c.eq(chunks.last!.end, wide.end, "chunk: last chunk ends at range end")
    c.eq(chunks[0].end, chunks[1].start, "chunk: chunks are contiguous")
    c.expect(chunks.allSatisfy { $0.duration <= maxSpan }, "chunk: each chunk ≤ maxSpan")
}

do {
    // Dedupe is part of the store contract — exercise it through store.events().
    let dwin = DateInterval(start: agToday, end: agToday.addingTimeInterval(10 * day))
    let dupStore = FakeCalendarStore(events: [
        .fixture(id: "dup", title: "Daily", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        .fixture(id: "dup", title: "Daily", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        .fixture(id: "dup", title: "Daily", start: agToday.addingTimeInterval(day + hour), end: agToday.addingTimeInterval(day + 2 * hour)),
    ])
    c.eq(dupStore.events(in: dwin, calendars: nil).count, 2, "store.events() collapses identical (id,start), keeps the distinct occurrence")
}

do {
    // Multi-day all-day events overlap a window over their middle day.
    let multi = EventInfo.fixture(id: "md", title: "Conference", calendar: "Work", start: agToday, end: agToday.addingTimeInterval(3 * day), allDay: true)
    let midWin = DateInterval(start: agToday.addingTimeInterval(day), end: agToday.addingTimeInterval(2 * day))
    c.eq(FakeCalendarStore(events: [multi]).events(in: midWin, calendars: nil).count, 1, "multi-day all-day event overlaps a window over its middle day")
    let line = try! runAgenda(store: FakeCalendarStore(events: [multi]), json: false, now: kstNow, timeZone: kst)
        .split(separator: "\n").first.map(String.init) ?? ""
    c.expect(line.contains(Output.localDate(agToday, timeZone: kst)), "multi-day all-day agenda row shows the start date")
}

do {
    // Reversed and DST windows drive event selection through the command, not just DateWindow.
    let evs = [EventInfo.fixture(id: "r", title: "X", calendar: "Work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    c.eq(try! runAgenda(store: FakeCalendarStore(events: evs), json: false, from: "2026-06-20", to: "2026-06-10", now: kstNow, timeZone: kst), "", "reversed --from/--to clamps to empty → no rows through the command")

    let ny = TimeZone(identifier: "America/New_York")!
    var nyCal2 = Calendar(identifier: .gregorian)
    nyCal2.timeZone = ny
    let nyNow = nyCal2.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
    let dstDay = nyCal2.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9))!
    let dstEvs = [EventInfo.fixture(id: "d", title: "DSTev", calendar: "Work", start: dstDay, end: dstDay.addingTimeInterval(hour))]
    let dstOut = try! runAgenda(store: FakeCalendarStore(events: dstEvs), json: false, from: "today", to: "+2d", now: nyNow, timeZone: ny)
    c.expect(dstOut.hasSuffix("\td\n") || dstOut.hasSuffix("\td"), "DST-spanning window selects an event on the spring-forward day through the command")
}

do {
    // mailto parsing: scheme strip, query drop, percent-decode, non-mailto → "".
    c.eq(EKCalendarStore.parseMailto("mailto:kim@example.com"), "kim@example.com", "parseMailto strips the scheme")
    c.eq(EKCalendarStore.parseMailto("mailto:kim@example.com?subject=Hi"), "kim@example.com", "parseMailto drops the query")
    c.eq(EKCalendarStore.parseMailto("MAILTO:Kim%20Lee@example.com"), "Kim Lee@example.com", "parseMailto is case-insensitive and percent-decodes")
    c.eq(EKCalendarStore.parseMailto("https://example.com/x"), "", "parseMailto returns empty for non-mailto urls")
}

do {
    // A tab/newline in a calendar title must not split or widen TSV rows.
    let evs = [
        EventInfo.fixture(id: "w", title: "WorkMtg", calendar: "Wo\trk\n", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "p", title: "Gym", calendar: "Personal", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour)),
    ]
    let out = try! runAgenda(store: FakeCalendarStore(events: evs), json: false, now: kstNow, timeZone: kst)
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.map(String.init)
    c.eq(lines.count, 2, "a tab/newline in a calendar title doesn't split a row")
    c.expect(lines.allSatisfy { $0.split(separator: "\t").count == 4 }, "multi-calendar rows stay rectangular after calendar sanitization")
}

// MARK: DateTime — datetime + duration parsing for writes

do {
    let (d1, only1) = try! DateTime.parse("2026-06-20", now: kstNow, timeZone: kst)
    c.eq(d1, try! DateWindow.parseBound("2026-06-20", now: kstNow, timeZone: kst), "DateTime date-only == DateWindow.parseBound")
    c.expect(only1, "date-only form → isDateOnly true")

    let expected = kstCal.date(byAdding: DateComponents(hour: 14, minute: 30),
                               to: kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20))!)!
    for form in ["2026-06-20T14:30", "2026-06-20 14:30"] {
        let (d, only) = try! DateTime.parse(form, now: kstNow, timeZone: kst)
        c.eq(d, expected, "timed form \(form) → expected instant")
        c.expect(!only, "timed form \(form) → isDateOnly false")
    }

    let tomorrow9 = kstCal.date(byAdding: DateComponents(hour: 9), to: try! DateWindow.parseBound("tomorrow", now: kstNow, timeZone: kst))!
    c.eq(try! DateTime.parse("tomorrow 09:00", now: kstNow, timeZone: kst).date, tomorrow9, "keyword+time resolves day + clock")
    c.eq(try! DateTime.parse("+1d 09:00", now: kstNow, timeZone: kst).date, tomorrow9, "+1d 09:00 == tomorrow 09:00")

    c.expect(throwsParsing { _ = try DateTime.parse("2026-02-30T10:00", now: kstNow, timeZone: kst) }, "impossible date+time throws")
    c.expect(throwsParsing { _ = try DateTime.parse("2026-06-20T25:61", now: kstNow, timeZone: kst) }, "out-of-range clock throws")
    c.expect(throwsParsing { _ = try DateTime.parse("2026-06-20T9:00", now: kstNow, timeZone: kst) }, "non-zero-padded clock throws")
}

do {
    let base = kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20))!
    let add: (String) -> Date = { kstCal.date(byAdding: try! DateTime.parseDuration($0), to: base)! }
    c.eq(add("90m"), add("1h30m"), "90m and 1h30m yield the same end")
    c.eq(add("1w2d"), kstCal.date(byAdding: .day, value: 9, to: base)!, "1w2d == +9 days")
    c.eq(add("2h"), kstCal.date(byAdding: .hour, value: 2, to: base)!, "2h == +2 hours")
    c.expect(throwsParsing { _ = try DateTime.parseDuration("30") }, "bare integer duration throws")
    c.expect(throwsParsing { _ = try DateTime.parseDuration("2m1h") }, "ascending-unit duration throws")
    c.expect(throwsParsing { _ = try DateTime.parseDuration("1h 30m") }, "spaced duration throws")
    c.expect(throwsParsing { _ = try DateTime.parseDuration("0m") }, "zero duration throws")
    c.expect(throwsParsing { _ = try DateTime.parseDuration("1h1h") }, "repeated unit throws")
}

// MARK: write seam — create / update / delete on a mutable Fake

func caught(_ body: () throws -> Void) -> Error? {
    do { try body(); return nil } catch { return error }
}

do {
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let store = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    c.eq(store.defaultWritableCalendar()?.title, "Work", "defaultWritableCalendar returns the configured default")

    let created = try! store.createEvent(EventDraft(title: "New", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)))
    c.expect(!created.id.isEmpty, "create assigns a non-empty id")
    c.eq(created.calendar, "Work", "create uses the default calendar when none given")
    c.eq(created.title, "New", "create carries the title")
    c.expect(store.event(id: created.id) != nil, "created event is visible via event(id:)")
    c.eq(try! store.createEvent(EventDraft(title: "ById", start: agToday, end: agToday.addingTimeInterval(hour), calendar: "cal-work")).calendar, "Work", "create resolves --calendar by identifier")
}

do {
    let store = FakeCalendarStore(calendars: [CalendarInfo.fixture(title: "Work")], defaultCalendar: nil)
    let d = EventDraft(title: "X", start: agToday, end: agToday.addingTimeInterval(hour), calendar: "Nope")
    c.eq(caught { _ = try store.createEvent(d) } as? WriteError, .calendarNotFound("Nope"), "unknown selector → calendarNotFound")
    c.eq(caught { _ = try store.createEvent(EventDraft(title: "X", start: agToday, end: agToday.addingTimeInterval(hour))) } as? WriteError, .noWritableCalendar, "no default calendar → noWritableCalendar")
    let ro = FakeCalendarStore(calendars: [CalendarInfo.fixture(title: "RO", writable: false)])
    c.eq(caught { _ = try ro.createEvent(EventDraft(title: "X", start: agToday, end: agToday.addingTimeInterval(hour), calendar: "RO")) } as? WriteError, .notWritable, "read-only target → notWritable")
}

do {
    let work = CalendarInfo.fixture(title: "Work")
    let store = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    let created = try! store.createEvent(EventDraft(title: "Orig", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), location: "Old"))
    let updated = try! store.updateEvent(id: created.id, EventChanges(title: "Renamed"), span: .thisEvent)
    c.eq(updated.title, "Renamed", "update changes the title")
    c.eq(updated.location, "Old", "update leaves nil fields untouched")
    c.eq(store.event(id: created.id)?.title, "Renamed", "update persists in the store")
    c.eq(try! store.updateEvent(id: created.id, EventChanges(location: ""), span: .thisEvent).location, "", "empty string clears location")
    _ = try! store.updateEvent(id: created.id, EventChanges(notes: "n"), span: .futureEvents)
    c.eq(store.lastSpan, .futureEvents, "update routes the WriteSpan to the store")
    c.eq(caught { _ = try store.updateEvent(id: "missing", EventChanges(title: "x"), span: .thisEvent) } as? WriteError, .notFound("missing"), "update missing id → notFound")
}

do {
    let ro = CalendarInfo.fixture(title: "RO", writable: false, calendarIdentifier: "cal-ro")
    let store = FakeCalendarStore(calendars: [ro])
    store.eventList = [EventInfo.fixture(id: "e1", calendar: "RO", calendarId: "cal-ro", start: agToday, end: agToday.addingTimeInterval(hour))]
    c.eq(caught { _ = try store.updateEvent(id: "e1", EventChanges(title: "x"), span: .thisEvent) } as? WriteError, .notWritable, "update on read-only calendar → notWritable")
    c.eq(caught { _ = try store.deleteEvent(id: "e1", span: .thisEvent) } as? WriteError, .notWritable, "delete on read-only calendar → notWritable")
}

do {
    let work = CalendarInfo.fixture(title: "Work")
    let store = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    let created = try! store.createEvent(EventDraft(title: "ToDelete", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)))
    let removed = try! store.deleteEvent(id: created.id, span: .thisEvent)
    c.eq(removed.id, created.id, "delete returns the removed event")
    c.expect(store.event(id: created.id) == nil, "deleted event is gone")
    c.eq(caught { _ = try store.deleteEvent(id: created.id, span: .thisEvent) } as? WriteError, .notFound(created.id), "delete of a gone id → notFound")
}

do {
    let work = CalendarInfo.fixture(title: "Work")
    let store = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    let created = try! store.createEvent(EventDraft(title: "PTO", start: agToday, end: agToday.addingTimeInterval(day), allDay: true))
    c.expect(created.allDay, "all-day create sets allDay")
    c.eq(created.end, agToday.addingTimeInterval(day), "all-day create keeps the exclusive next-midnight end")
    c.eq(created.timeZone, "", "all-day create leaves timeZone empty (floating)")

    let base = EventInfo.fixture(id: "x", start: agToday, end: agToday.addingTimeInterval(hour), location: "L", notes: "N")
    c.eq(base.applying(EventChanges(location: "")).location, "", "applying an empty string clears the field")
    c.eq(base.applying(EventChanges(notes: "n2")).location, "L", "applying leaves nil fields unchanged")
}

// MARK: add — runAdd

func newStore() -> FakeCalendarStore {
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    return FakeCalendarStore(calendars: [work], defaultCalendar: work)
}

do {
    let store = newStore()
    let r = try! runAdd(store: store, title: "Lunch", start: "2026-06-20T12:00", end: nil, duration: "1h",
                        allDay: false, calendar: nil, tz: nil, location: nil, notes: nil, url: nil,
                        availability: nil, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.expect(r.performed, "runAdd with AutoYes creates the event")
    c.expect(r.output.contains("Title:") && r.output.contains("Lunch"), "add echoes a show-style block")
    c.eq(store.eventList.count, 1, "add appended one event")
    let startD = try! DateTime.parse("2026-06-20T12:00", now: kstNow, timeZone: kst).date
    c.eq(store.eventList[0].end, startD.addingTimeInterval(3600), "--duration 1h resolves end = start + 1h")
}

do {
    let store = newStore()
    let r = try! runAdd(store: store, title: "Sync", start: "2026-06-20T09:00", end: "2026-06-20T09:30", duration: nil,
                        allDay: false, calendar: nil, tz: nil, location: "Room", notes: nil, url: nil,
                        availability: nil, json: true, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.expect(r.output.contains("\"title\":\"Sync\""), "add --json echoes the event object")
    c.expect(r.output.contains("\"id\":\"fake-"), "add --json includes the assigned id")
}

do {
    let store = newStore()
    let r = try! runAdd(store: store, title: "Preview", start: "2026-06-20T10:00", end: nil, duration: "30m",
                        allDay: false, calendar: nil, tz: nil, location: nil, notes: nil, url: nil,
                        availability: nil, json: false, dryRun: true, confirm: AutoNo(), now: kstNow, timeZone: kst)
    c.expect(!r.performed, "dry-run does not write")
    c.expect(r.output.contains("Preview"), "dry-run still renders the preview")
    c.eq(store.eventList.count, 0, "dry-run leaves the store unchanged")
}

do {
    let store = newStore()
    let r = try! runAdd(store: store, title: "Nope", start: "2026-06-20T10:00", end: nil, duration: "30m",
                        allDay: false, calendar: nil, tz: nil, location: nil, notes: nil, url: nil,
                        availability: nil, json: false, dryRun: false, confirm: AutoNo(), now: kstNow, timeZone: kst)
    c.eq(r, .aborted, "AutoNo aborts the create")
    c.eq(store.eventList.count, 0, "an aborted add writes nothing")
}

do {
    let store = newStore()
    func addErr(_ title: String, _ start: String, end: String? = nil, duration: String? = nil, allDay: Bool = false, availability: String? = nil) -> Error? {
        caught {
            _ = try runAdd(store: store, title: title, start: start, end: end, duration: duration, allDay: allDay,
                           calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: availability,
                           json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
        }
    }
    c.eq(addErr("", "2026-06-20T10:00", duration: "1h") as? WriteValidationError, .emptyTitle, "empty title → emptyTitle")
    c.eq(addErr("X", "2026-06-20T10:00", end: "2026-06-20T11:00", duration: "1h") as? WriteValidationError, .endAndDurationConflict, "--end + --duration → conflict")
    c.eq(addErr("X", "2026-06-20T10:00") as? WriteValidationError, .missingEnd, "timed add with neither end nor duration → missingEnd")
    c.eq(addErr("X", "2026-06-20T10:00", duration: "1h", allDay: true) as? WriteValidationError, .allDayWithTime, "--all-day with a timed start → allDayWithTime")
    c.eq(addErr("X", "2026-06-20T10:00", duration: "1h", availability: "bogus") as? WriteValidationError, .invalidAvailability("bogus"), "bad availability → invalidAvailability")
}

do {
    let store = newStore()
    _ = try! runAdd(store: store, title: "PTO", start: "2026-07-01", end: nil, duration: nil, allDay: false,
                    calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                    json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.expect(store.eventList[0].allDay, "a date-only start infers an all-day event")
    let day1 = try! DateWindow.parseBound("2026-07-01", now: kstNow, timeZone: kst)
    c.eq(store.eventList[0].end, kstCal.date(byAdding: .day, value: 1, to: day1)!, "all-day default end is the next day")
}

do {
    let store = newStore()
    let err = caught {
        _ = try runAdd(store: store, title: "X", start: "2026-06-20T10:00", end: nil, duration: "1h", allDay: false,
                       calendar: "Ghost", tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                       json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    }
    c.eq(err as? WriteError, .calendarNotFound("Ghost"), "unknown --calendar surfaces calendarNotFound through runAdd")
}

// MARK: edit — runEdit

@MainActor func editStore() -> FakeCalendarStore {
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let personal = CalendarInfo.fixture(title: "Personal", calendarIdentifier: "cal-personal")
    let s = FakeCalendarStore(calendars: [work, personal], defaultCalendar: work)
    s.eventList = [EventInfo.fixture(
        id: "E1", title: "Orig", calendar: "Work", calendarId: "cal-work",
        start: kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 10))!,
        end: kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 11))!,
        timeZone: "Asia/Seoul", location: "Old"
    )]
    return s
}

@MainActor func edit(_ s: FakeCalendarStore, id: String = "E1", title: String? = nil, start: String? = nil, end: String? = nil,
          duration: String? = nil, tz: String? = nil, location: String? = nil, notes: String? = nil, url: String? = nil,
          availability: String? = nil, calendar: String? = nil, allOccurrences: Bool = false, json: Bool = false, dryRun: Bool = false,
          confirm: Confirmer = AutoYes()) throws -> WriteResult {
    try runEdit(store: s, id: id, title: title, start: start, end: end, duration: duration, tz: tz,
                location: location, notes: notes, url: url, availability: availability, calendar: calendar,
                allOccurrences: allOccurrences, json: json, dryRun: dryRun, confirm: confirm, now: kstNow, timeZone: kst)
}

do {
    let s = editStore()
    c.expect(try! edit(s, title: "Renamed").performed, "edit applies the change")
    c.eq(s.event(id: "E1")?.title, "Renamed", "edit changes the title")
    c.eq(s.event(id: "E1")?.location, "Old", "edit leaves untouched fields")
}

do {
    // --calendar moves the event to another (writable) calendar.
    let s = editStore()
    _ = try! edit(s, calendar: "Personal")
    c.eq(s.event(id: "E1")?.calendar, "Personal", "edit --calendar moves the event")
    c.eq(s.event(id: "E1")?.calendarId, "cal-personal", "moved event's calendarId updates")
    c.eq(caught { _ = try edit(s, calendar: "Nope") } as? WriteError, .calendarNotFound("Nope"),
         "unknown --calendar → calendarNotFound")
}

do {
    // edit <id>@<epoch>: detach-edit one occurrence (non-schedule fields only).
    let s = syncStore([EventInfo.fixture(id: "R", title: "Weekly", calendar: "Work", calendarId: "cal-work",
                                         start: agToday.addingTimeInterval(day), end: agToday.addingTimeInterval(day + hour),
                                         location: "Room A", recurring: true)])
    let d2 = agToday.addingTimeInterval(2 * day)
    s.seriesOccurrenceDates["R"] = [agToday.addingTimeInterval(day), d2]  // real occurrences (as agenda would show)
    let handle = Output.occurrenceHandle(id: "R", start: d2)
    if case .wrote(let out) = try! edit(s, id: handle, location: "Room B") {
        c.expect(out.contains("Room B"), "edit occurrence applies a non-schedule change")
    } else { c.expect(false, "edit occurrence returns .wrote") }
    c.eq(caught { _ = try edit(s, id: handle, start: "2026-06-20T14:00") } as? WriteValidationError,
         .occurrenceScheduleUnsupported, "edit <handle> --start → occurrenceScheduleUnsupported")
    c.eq(caught { _ = try edit(s, id: handle, calendar: "Personal") } as? WriteValidationError,
         .occurrenceScheduleUnsupported, "edit <handle> --calendar → occurrenceScheduleUnsupported")
}

do {
    let s = editStore()
    _ = try! edit(s, location: "")
    c.eq(s.event(id: "E1")?.location, "", "edit --location '' clears the location")
}

do {
    let s = editStore()
    _ = try! edit(s, start: "2026-06-20T14:00")
    let e = s.event(id: "E1")!
    c.eq(e.end.timeIntervalSince(e.start), 3600, "moving start alone keeps the 1h duration")
    c.eq(e.start, kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 14))!, "start moved to 14:00")
}

do {
    // Keep-duration is DST-safe: moving --start re-adds the wall-clock span in
    // calendar components, not a raw second delta. A 2-day event spanning the
    // spring-forward night (2026-03-08 in America/Los_Angeles, so 47h elapsed)
    // moved to a normal week must stay 2 wall-clock days (end at 12:00), not
    // land at 11:00 from a raw 47h delta.
    let la = TimeZone(identifier: "America/Los_Angeles")!
    var laCal = Calendar(identifier: .gregorian); laCal.timeZone = la
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let s = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    s.eventList = [EventInfo.fixture(
        id: "E1", title: "Trip", calendar: "Work", calendarId: "cal-work",
        start: laCal.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!,
        end: laCal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!,
        timeZone: "America/Los_Angeles"
    )]
    let now = laCal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
    _ = try! runEdit(store: s, id: "E1", title: nil, start: "2026-03-15T12:00", end: nil, duration: nil,
                     tz: nil, location: nil, notes: nil, url: nil, availability: nil, calendar: nil,
                     allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), now: now, timeZone: la)
    c.eq(s.event(id: "E1")?.end, laCal.date(from: DateComponents(year: 2026, month: 3, day: 17, hour: 12))!,
         "edit keep-duration preserves wall-clock span across DST (end 12:00, not 11:00)")
}

do {
    let s = editStore()
    c.eq(caught { _ = try edit(s, end: "2026-06-20T12:00", duration: "1h") } as? WriteValidationError, .endAndDurationConflict, "--end + --duration → conflict")
    c.eq(caught { _ = try edit(s) } as? WriteValidationError, .noChanges, "no field flags → noChanges")
    c.eq(caught { _ = try edit(s, id: "GHOST", title: "x") } as? WriteError, .notFound("GHOST"), "edit missing id → notFound")
}

do {
    let s = editStore()
    _ = try! edit(s, notes: "agenda", allOccurrences: true)
    c.eq(s.lastSpan, .futureEvents, "edit --all-occurrences routes WriteSpan.futureEvents")
    let s2 = editStore()
    _ = try! edit(s2, notes: "x")
    c.eq(s2.lastSpan, .thisEvent, "edit default routes WriteSpan.thisEvent")
}

do {
    let s = editStore()
    let r = try! edit(s, title: "NewName", dryRun: true, confirm: AutoNo())
    c.expect(!r.performed, "edit dry-run does not write")
    c.expect(r.output.contains("Title") && r.output.contains("→"), "edit dry-run renders a before→after diff")
    c.eq(s.event(id: "E1")?.title, "Orig", "edit dry-run leaves the event unchanged")

    let aborted = try! edit(editStore(), title: "X", confirm: AutoNo())
    c.eq(aborted, .aborted, "edit AutoNo aborts")
}

// MARK: rm — runRm

@MainActor func rmStore() -> FakeCalendarStore {
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let s = FakeCalendarStore(calendars: [work], defaultCalendar: work)
    s.eventList = [EventInfo.fixture(id: "R1", title: "Demo", calendar: "Work", calendarId: "cal-work",
                                     start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    return s
}

do {
    let s = rmStore()
    let r = try! runRm(store: s, id: "R1", allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst)
    c.expect(r.performed, "rm deletes with AutoYes")
    c.expect(r.output.contains("deleted R1 — Demo"), "rm prints 'deleted <id> — <title>'")
    c.expect(s.event(id: "R1") == nil, "rm removes the event")
}

do {
    let s = rmStore()
    let r = try! runRm(store: s, id: "R1", allOccurrences: false, json: true, dryRun: false, confirm: AutoYes(), timeZone: kst)
    c.expect(r.output.contains("\"id\":\"R1\"") && r.output.contains("\"title\":\"Demo\""), "rm --json emits the deleted event object")
    c.eq(r.output.split(separator: "\n").count, 1, "rm --json is a single object line")
}

do {
    let s = rmStore()
    let r = try! runRm(store: s, id: "R1", allOccurrences: false, json: false, dryRun: true, confirm: AutoNo(), timeZone: kst)
    c.expect(!r.performed, "rm dry-run deletes nothing")
    c.expect(r.output.contains("Demo"), "rm dry-run shows the target event")
    c.expect(s.event(id: "R1") != nil, "rm dry-run leaves the event")
}

do {
    let s = rmStore()
    c.eq(try! runRm(store: s, id: "R1", allOccurrences: false, json: false, dryRun: false, confirm: AutoNo(), timeZone: kst), .aborted, "rm AutoNo aborts")
    c.expect(s.event(id: "R1") != nil, "an aborted rm keeps the event")
}

do {
    let s = rmStore()
    c.eq(caught { _ = try runRm(store: s, id: "GONE", allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst) } as? WriteError, .notFound("GONE"), "rm missing id → notFound")
    _ = try! runRm(store: s, id: "R1", allOccurrences: true, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst)
    c.eq(s.lastSpan, .futureEvents, "rm --all-occurrences routes WriteSpan.futureEvents")
}

do {
    let ro = CalendarInfo.fixture(title: "RO", writable: false, calendarIdentifier: "cal-ro")
    let s = FakeCalendarStore(calendars: [ro])
    s.eventList = [EventInfo.fixture(id: "X", calendar: "RO", calendarId: "cal-ro", start: agToday, end: agToday.addingTimeInterval(hour))]
    c.eq(caught { _ = try runRm(store: s, id: "X", allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst) } as? WriteError, .notWritable, "rm on a read-only calendar → notWritable")
}

// MARK: M3 review hardening

do {
    // all-day add rejects a sub-day --duration (parity with the --end spelling).
    let s = newStore()
    c.eq(caught {
        _ = try runAdd(store: s, title: "PTO", start: "2026-07-01", end: nil, duration: "90m", allDay: true,
                       calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                       json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    } as? WriteValidationError, .allDayWithTime, "all-day + sub-day --duration → allDayWithTime")
    _ = try! runAdd(store: s, title: "Trip", start: "2026-07-01", end: nil, duration: "2d", allDay: true,
                    calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                    json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.expect(s.eventList.last!.allDay, "all-day + whole-day --duration is accepted")
}

do {
    // all-day add: explicit date-only --end; mixed date-only/timed bounds error.
    let s = newStore()
    _ = try! runAdd(store: s, title: "Conf", start: "2026-07-01", end: "2026-07-03", duration: nil, allDay: true,
                    calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                    json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.eq(s.eventList.last!.end, try! DateWindow.parseBound("2026-07-03", now: kstNow, timeZone: kst), "all-day explicit date-only end honored")
    func mixErr(_ start: String, _ end: String) -> Error? {
        caught { _ = try runAdd(store: s, title: "X", start: start, end: end, duration: nil, allDay: false,
                                calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                                json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) }
    }
    c.eq(mixErr("2026-06-20T10:00", "2026-06-21") as? WriteValidationError, .allDayWithTime, "timed start + date-only end → allDayWithTime")
    c.eq(mixErr("2026-06-20", "2026-06-21T10:00") as? WriteValidationError, .allDayWithTime, "date-only start + timed end → allDayWithTime")
}

do {
    // add: endNotAfterStart, invalidURL, availability persistence, ambiguousCalendar.
    let s = newStore()
    func aerr(_ start: String, end: String? = nil, duration: String? = nil, url: String? = nil) -> Error? {
        caught { _ = try runAdd(store: s, title: "X", start: start, end: end, duration: duration, allDay: false,
                                calendar: nil, tz: nil, location: nil, notes: nil, url: url, availability: nil,
                                json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) }
    }
    c.eq(aerr("2026-06-20T10:00", end: "2026-06-20T09:00") as? WriteValidationError, .endNotAfterStart, "add end before start → endNotAfterStart")
    c.eq(aerr("2026-06-20T10:00", duration: "1h", url: "http://a b") as? WriteValidationError, .invalidURL("http://a b"), "add malformed url → invalidURL")
    _ = try! runAdd(store: s, title: "Free", start: "2026-06-20T10:00", end: nil, duration: "1h", allDay: false,
                    calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: "free",
                    json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.eq(s.eventList.last!.availability, "free", "add persists a non-default availability")
    let ambig = FakeCalendarStore(calendars: [
        CalendarInfo.fixture(title: "Work", calendarIdentifier: "w1"),
        CalendarInfo.fixture(title: "Work", calendarIdentifier: "w2"),
    ])
    c.eq(caught { _ = try runAdd(store: ambig, title: "X", start: "2026-06-20T10:00", end: nil, duration: "1h", allDay: false,
                                 calendar: "Work", tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                                 json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) } as? WriteError,
         .ambiguousCalendar("Work"), "ambiguous --calendar → ambiguousCalendar")
}

do {
    // add --tz: authoring zone stored + start parsed in that zone; bad tz rejected.
    let s = newStore()
    _ = try! runAdd(store: s, title: "NY", start: "2026-06-20T09:00", end: nil, duration: "1h", allDay: false,
                    calendar: nil, tz: "America/New_York", location: nil, notes: nil, url: nil, availability: nil,
                    json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    c.eq(s.eventList.last!.timeZone, "America/New_York", "add --tz stored as the authoring zone")
    let ny = TimeZone(identifier: "America/New_York")!
    c.eq(s.eventList.last!.start, try! DateTime.parse("2026-06-20T09:00", now: kstNow, timeZone: ny).date, "add --tz parses start in that zone")
    c.eq(caught { _ = try runAdd(store: s, title: "X", start: "2026-06-20T09:00", end: nil, duration: "1h", allDay: false,
                                 calendar: nil, tz: "Not/AZone", location: nil, notes: nil, url: nil, availability: nil,
                                 json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) } as? WriteValidationError,
         .invalidTimeZone("Not/AZone"), "add invalid --tz → invalidTimeZone")
}

do {
    // add --json id is present and non-empty (store-agnostic).
    let s = newStore()
    let r = try! runAdd(store: s, title: "J", start: "2026-06-20T09:00", end: nil, duration: "1h", allDay: false,
                        calendar: nil, tz: nil, location: nil, notes: nil, url: nil, availability: nil,
                        json: true, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    let line = r.output.split(separator: "\n").first.map(String.init) ?? ""
    let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    c.expect((obj?["id"] as? String).map { !$0.isEmpty } ?? false, "add --json id is present and non-empty")
}

do {
    // edit/rm: a recurring event requires --all-occurrences.
    let s = editStore()
    s.eventList[0] = EventInfo.fixture(id: "E1", title: "Daily", calendar: "Work", calendarId: "cal-work",
                                       start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), recurring: true)
    c.eq(caught { _ = try edit(s, notes: "x") } as? WriteValidationError, .recurringRequiresAllOccurrences, "edit recurring without --all-occurrences → error")
    _ = try! edit(s, notes: "x", allOccurrences: true)
    c.eq(s.lastSpan, .futureEvents, "edit recurring with --all-occurrences applies to the series")

    let r = rmStore()
    r.eventList[0] = EventInfo.fixture(id: "R1", title: "Daily", calendar: "Work", calendarId: "cal-work",
                                       start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), recurring: true)
    c.eq(caught { _ = try runRm(store: r, id: "R1", allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst) } as? WriteValidationError,
         .recurringRequiresAllOccurrences, "rm recurring without --all-occurrences → error")
    _ = try! runRm(store: r, id: "R1", allOccurrences: true, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst)
    c.expect(r.event(id: "R1") == nil, "rm recurring with --all-occurrences deletes it")
}

do {
    // edit: explicit end / duration alone; endNotAfterStart; --tz; clears.
    let s = editStore()
    _ = try! edit(s, duration: "2h")
    c.eq(s.event(id: "E1")!.end.timeIntervalSince(s.event(id: "E1")!.start), 7200, "edit --duration alone sets end = start + 2h")
    c.eq(s.event(id: "E1")!.start, kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 10))!, "edit --duration leaves start")
    let s2 = editStore()
    _ = try! edit(s2, end: "2026-06-20T12:00")
    c.eq(s2.event(id: "E1")!.end, kstCal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 12))!, "edit explicit --end moves end")
    c.eq(caught { _ = try edit(editStore(), end: "2026-06-20T09:00") } as? WriteValidationError, .endNotAfterStart, "edit end before start → endNotAfterStart")
    let s3 = editStore()
    _ = try! edit(s3, tz: "America/New_York")
    c.eq(s3.event(id: "E1")!.timeZone, "America/New_York", "edit --tz updates the authoring zone")
    c.expect(throwsParsing { _ = try edit(editStore(), tz: "Not/AZone") }, "edit invalid --tz throws")
    let s4 = editStore()
    _ = try! edit(s4, notes: "")
    c.eq(s4.event(id: "E1")!.notes, "", "edit --notes '' clears notes")
    let s5 = editStore()
    _ = try! edit(s5, url: "")
    c.eq(s5.event(id: "E1")!.url, "", "edit --url '' clears url")
    c.eq(caught { _ = try edit(editStore(), url: "http://a b") } as? WriteValidationError, .invalidURL("http://a b"), "edit malformed url → invalidURL")
}

do {
    // edit diff body: changed fields appear, unchanged don't.
    let r = try! edit(editStore(), location: "Room 9", dryRun: true, confirm: AutoNo())
    c.expect(r.output.contains("Location: Old → Room 9"), "diff shows the location change")
    c.expect(!r.output.contains("Notes:"), "diff omits unchanged fields")
    let r2 = try! edit(editStore(), notes: "agenda", dryRun: true, confirm: AutoNo())
    c.expect(r2.output.contains("Notes: (none) → agenda"), "diff renders a (none) → value change")
    let r3 = try! edit(editStore(), availability: "free", dryRun: true, confirm: AutoNo())
    c.expect(r3.output.contains("Availability: busy → free"), "diff shows the availability change")
}

do {
    // edit all-day: sub-day duration / timed start rejected; date-only move stays all-day.
    let s = editStore()
    s.eventList[0] = EventInfo.fixture(id: "E1", title: "Holiday", calendar: "Work", calendarId: "cal-work",
                                       start: agToday, end: agToday.addingTimeInterval(day), allDay: true)
    c.eq(caught { _ = try edit(s, duration: "2h") } as? WriteValidationError, .allDayWithTime, "edit all-day + sub-day duration → allDayWithTime")
    c.eq(caught { _ = try edit(s, start: "2026-06-22T10:00") } as? WriteValidationError, .allDayWithTime, "edit all-day + timed start → allDayWithTime")
    _ = try! edit(s, start: "2026-06-22")
    c.expect(s.event(id: "E1")!.allDay, "edit all-day with a date-only start stays all-day")
}

do {
    // applying(): all-day clears the zone; timed retains/updates it.
    let timed = EventInfo.fixture(id: "z", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), timeZone: "Asia/Seoul")
    c.eq(timed.applying(EventChanges(notes: "n")).timeZone, "Asia/Seoul", "applying retains the zone when unchanged")
    c.eq(timed.applying(EventChanges(timeZoneId: "UTC")).timeZone, "UTC", "applying updates the zone")
    c.eq(timed.applying(EventChanges(allDay: true, timeZoneId: "UTC")).timeZone, "", "applying all-day clears the zone (wins over explicit tz)")
}

do {
    // availability string<->enum round-trips (the user-driven mapper).
    for v in ["busy", "free", "tentative", "unavailable"] {
        c.eq(EKCalendarStore.availabilityString(EKCalendarStore.availabilityValue(v)), v, "availability round-trips: \(v)")
    }
    c.eq(EKCalendarStore.availabilityValue("garbage"), .busy, "unknown availability → busy")
}

do {
    // DateTime: seconds form + keyword/relative + time.
    let withSec = try! DateTime.parse("2026-06-20T14:30:45", now: kstNow, timeZone: kst).date
    let base = try! DateTime.parse("2026-06-20T14:30", now: kstNow, timeZone: kst).date
    c.eq(withSec, base.addingTimeInterval(45), "HH:MM:SS adds the seconds")
    c.expect(throwsParsing { _ = try DateTime.parse("2026-06-20T14:30:99", now: kstNow, timeZone: kst) }, "out-of-range seconds throws")
    let today8 = kstCal.date(byAdding: DateComponents(hour: 8), to: kstCal.startOfDay(for: kstNow))!
    c.eq(try! DateTime.parse("today 08:00", now: kstNow, timeZone: kst).date, today8, "today 08:00 resolves")
}

do {
    // Duration: single d/w + full descending chain (component-level).
    let chain = try! DateTime.parseDuration("1w1d1h1m")
    c.eq(chain.weekOfYear, 1, "chain parses weeks")
    c.eq(chain.day, 1, "chain parses days")
    c.eq(chain.hour, 1, "chain parses hours")
    c.eq(chain.minute, 1, "chain parses minutes")
    c.eq(try! DateTime.parseDuration("1d").day, 1, "1d → day 1")
    c.eq(try! DateTime.parseDuration("1w").weekOfYear, 1, "1w → weekOfYear 1")
}

// MARK: htmlToPlain — Notes HTML → plain text

do {
    c.eq(Output.htmlToPlain("plain text"), "plain text", "non-HTML passes through unchanged")
    c.eq(Output.htmlToPlain("a<br>b"), "a\nb", "<br> → newline")
    c.eq(Output.htmlToPlain("a<br/>b<br />c"), "a\nb\nc", "<br/> variants → newline")
    c.eq(Output.htmlToPlain("<b>Bold</b> rest"), "Bold rest", "inline tags stripped")
    c.eq(Output.htmlToPlain("<a href=\"https://x.com\">link</a>"), "link (https://x.com)", "anchor → text (url)")
    c.eq(Output.htmlToPlain("<a href=\"https://x.com\">https://x.com</a>"), "https://x.com", "anchor whose text is the url → url only")
    c.eq(Output.htmlToPlain("A &amp; B &lt;tag&gt;"), "A & B <tag>", "entities decoded (amp last)")
    let list = Output.htmlToPlain("<ul><li>one</li><li>two</li></ul>")
    c.expect(list.contains("- one") && list.contains("- two"), "list items → bullets: \(list)")
    c.eq(Output.htmlToPlain("x<br><br><br>y"), "x\n\ny", "blank runs collapsed")
}

// MARK: sync — runSync one-way mirror (work → personal)

@MainActor func syncStore(_ events: [EventInfo], targetWritable: Bool = true) -> FakeCalendarStore {
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let personal = CalendarInfo.fixture(title: "Personal", writable: targetWritable, calendarIdentifier: "cal-personal")
    return FakeCalendarStore(calendars: [work, personal], events: events, defaultCalendar: personal)
}
@MainActor func srcEvent(_ id: String, _ title: String, _ offsetHours: Double,
                         location: String = "", notes: String = "") -> EventInfo {
    EventInfo.fixture(id: id, title: title, calendar: "Work", calendarId: "cal-work",
                      start: agToday.addingTimeInterval(offsetHours * hour),
                      end: agToday.addingTimeInterval((offsetHours + 1) * hour),
                      location: location, notes: notes)
}
@MainActor func syncRun(_ s: FakeCalendarStore, detail: SyncDetail = .titleTimeLocation,
                        noDelete: Bool = false, dryRun: Bool = false, confirm: Confirmer = AutoYes()) throws -> WriteResult {
    try runSync(store: s, from: ["Work"], to: "Personal", since: nil, until: nil,
                detail: detail, noDelete: noDelete, json: false, dryRun: dryRun,
                confirm: confirm, now: kstNow, timeZone: kst)
}
@MainActor func syncedCopies(_ s: FakeCalendarStore) -> [EventInfo] {
    s.events(in: DateInterval(start: agToday, end: agToday.addingTimeInterval(40 * day)), calendars: ["cal-personal"])
}

do {
    // marker round-trips (srcId, start); non-markers are ignored.
    let mk = makeSyncMarker(srcId: "W1:abc-123", start: agToday.addingTimeInterval(hour))
    let p = parseSyncMarker(mk)
    c.eq(p?.srcId, "W1:abc-123", "sync marker round-trips srcId")
    c.eq(p?.start, agToday.addingTimeInterval(hour), "sync marker round-trips start")
    c.expect(parseSyncMarker("https://example.com/x") == nil, "non-marker url → nil")
    c.expect(parseSyncMarker("") == nil, "empty url → nil")
}

do {
    // initial sync copies source events into the target, each with a marker.
    let s = syncStore([srcEvent("W1", "Standup", 1, location: "Room 4F", notes: "sync me")])
    let r = try! syncRun(s)
    c.expect(r.performed, "sync writes on the first run")
    let copies = syncedCopies(s)
    c.eq(copies.count, 1, "sync creates one target copy")
    c.eq(copies[0].title, "Standup", "copy keeps the title")
    c.eq(copies[0].calendar, "Personal", "copy lands in the target calendar")
    c.eq(copies[0].location, "Room 4F", "default detail copies location")
    c.expect(copies[0].notes.isEmpty, "default detail does NOT copy notes")
    c.eq(parseSyncMarker(copies[0].url)?.srcId, "W1", "copy carries a marker naming its source")
}

do {
    // Empty-id source events are skipped: their marker's srcId would be empty and
    // parseSyncMarker can't read it back, so the copy would be unmanaged
    // (re-created every run). Only id-bearing events mirror.
    let s = syncStore([srcEvent("", "Ghost", 1), srcEvent("E1", "Real", 2)])
    _ = try! syncRun(s)
    let copies = syncedCopies(s)
    c.eq(copies.count, 1, "sync skips the empty-id source event")
    c.eq(copies.first?.title, "Real", "only the id-bearing source event is mirrored")
}

do {
    // idempotent: a re-sync with no source change writes nothing, no duplicates.
    let s = syncStore([srcEvent("W1", "Standup", 1)])
    _ = try! syncRun(s)
    let r2 = try! syncRun(s)
    c.expect(r2.output.contains("up to date"), "second sync with no change is a no-op (reports 'up to date')")
    c.eq(syncedCopies(s).count, 1, "re-sync does not duplicate the copy")
}

do {
    // a changed source event updates its copy in place (no duplicate).
    let s = syncStore([srcEvent("W1", "Standup", 1)])
    _ = try! syncRun(s)
    s.eventList[0] = srcEvent("W1", "Standup RENAMED", 1)
    let r = try! syncRun(s)
    c.expect(r.performed, "sync updates a changed source event")
    let copies = syncedCopies(s)
    c.eq(copies.count, 1, "update does not create a duplicate")
    c.eq(copies[0].title, "Standup RENAMED", "the copy reflects the source edit")
}

do {
    // mirror delete: a source occurrence that's gone removes its copy.
    let s = syncStore([srcEvent("W1", "Standup", 1), srcEvent("W2", "Lunch", 3)])
    _ = try! syncRun(s)
    c.eq(syncedCopies(s).count, 2, "both copied initially")
    s.eventList.removeAll { $0.id == "W2" }
    let r = try! syncRun(s)
    c.expect(r.performed, "sync removes a copy whose source is gone")
    let copies = syncedCopies(s)
    c.eq(copies.count, 1, "mirror deletes the orphaned copy")
    c.eq(copies[0].title, "Standup", "the surviving copy is the one still in source")
}

do {
    // --no-delete keeps an orphaned copy.
    let s = syncStore([srcEvent("W1", "Standup", 1), srcEvent("W2", "Lunch", 3)])
    _ = try! syncRun(s)
    s.eventList.removeAll { $0.id == "W2" }
    _ = try! syncRun(s, noDelete: true)
    c.eq(syncedCopies(s).count, 2, "--no-delete keeps the orphaned copy")
}

do {
    // location/notes off drop those fields but keep the (mandatory) title.
    let s = syncStore([srcEvent("W1", "Secret 1:1", 1, location: "Room 4F", notes: "sensitive")])
    _ = try! syncRun(s, detail: [.title])
    let copy = syncedCopies(s)[0]
    c.eq(copy.title, "Secret 1:1", "title is always kept")
    c.expect(copy.location.isEmpty, "location off drops the location")
    c.expect(copy.notes.isEmpty, "notes off drops notes")
}

do {
    // notes detail copies the body.
    let s = syncStore([srcEvent("W1", "Planning", 1, notes: "agenda: Q3")])
    _ = try! syncRun(s, detail: .withNotes)
    c.eq(syncedCopies(s)[0].notes, "agenda: Q3", "notes detail copies the body")
}

do {
    // errors: same source/target, unknown source, read-only target.
    let s = syncStore([srcEvent("W1", "X", 1)])
    c.eq(caught { _ = try runSync(store: s, from: ["Work"], to: "Work", since: nil, until: nil, detail: .titleTimeLocation, noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) } as? WriteValidationError, .sameSourceTarget, "same --from/--to → sameSourceTarget")
    c.eq(caught { _ = try runSync(store: s, from: ["Ghost"], to: "Personal", since: nil, until: nil, detail: .titleTimeLocation, noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) } as? WriteError, .calendarNotFound("Ghost"), "unknown source → calendarNotFound")
    let ro = syncStore([srcEvent("W1", "X", 1)], targetWritable: false)
    c.eq(caught { _ = try runSync(store: ro, from: ["Work"], to: "Personal", since: nil, until: nil, detail: .titleTimeLocation, noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst) } as? WriteError, .notWritable, "read-only target → notWritable")
}

do {
    // dry-run shows the plan and writes nothing.
    let s = syncStore([srcEvent("W1", "Standup", 1)])
    let r = try! syncRun(s, dryRun: true, confirm: AutoNo())
    c.expect(!r.performed, "dry-run writes nothing")
    c.expect(r.output.contains("would sync") && r.output.contains("Standup"), "dry-run shows the plan")
    c.eq(syncedCopies(s).count, 0, "dry-run leaves the target empty")
}

do {
    // declining the confirmation aborts without writing.
    let s = syncStore([srcEvent("W1", "Standup", 1)])
    c.eq(try! syncRun(s, confirm: AutoNo()), .aborted, "declining aborts the sync")
    c.eq(syncedCopies(s).count, 0, "an aborted sync writes nothing")
}

do {
    // "Account/Calendar" selector disambiguates a title shared across accounts.
    let a = CalendarInfo.fixture(title: "Cal", source: "AcctA", calendarIdentifier: "cal-a")
    let b = CalendarInfo.fixture(title: "Cal", source: "AcctB", calendarIdentifier: "cal-b")
    let dst = CalendarInfo.fixture(title: "Dst", calendarIdentifier: "cal-dst")
    let s = FakeCalendarStore(calendars: [a, b, dst], defaultCalendar: dst)
    s.eventList = [EventInfo.fixture(id: "X", title: "E", calendar: "Cal", calendarId: "cal-a",
                                     start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour))]
    let run: (String) throws -> WriteResult = { sel in
        try runSync(store: s, from: [sel], to: "Dst", since: nil, until: nil, detail: .titleTimeLocation,
                    noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    }
    c.eq(caught { _ = try run("Cal") } as? WriteError, .ambiguousCalendar("Cal"), "bare title shared by two calendars → ambiguous")
    c.expect(try! run("AcctA/Cal").performed, "Account/Calendar selector resolves the ambiguity")
    c.eq(s.events(in: DateInterval(start: agToday, end: agToday.addingTimeInterval(40 * day)), calendars: ["cal-dst"]).count, 1, "one event copied from AcctA/Cal")
}

do {
    // multiple --from sources union into one target.
    let work = CalendarInfo.fixture(title: "Work", calendarIdentifier: "cal-work")
    let team = CalendarInfo.fixture(title: "Team", calendarIdentifier: "cal-team")
    let personal = CalendarInfo.fixture(title: "Personal", calendarIdentifier: "cal-personal")
    let s = FakeCalendarStore(calendars: [work, team, personal], defaultCalendar: personal)
    s.eventList = [
        EventInfo.fixture(id: "W1", title: "Standup", calendar: "Work", calendarId: "cal-work", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "T1", title: "Review", calendar: "Team", calendarId: "cal-team", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour)),
    ]
    _ = try! runSync(store: s, from: ["Work", "Team"], to: "Personal", since: nil, until: nil, detail: .titleTimeLocation, noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    let copies = s.events(in: DateInterval(start: agToday, end: agToday.addingTimeInterval(40 * day)), calendars: ["cal-personal"])
    c.eq(copies.count, 2, "both --from sources are mirrored into one target")
    c.eq(Set(copies.map { $0.title }), ["Standup", "Review"], "target holds the union of the sources")
}

do {
    // duplicate copies of one source occurrence converge back to a single copy.
    let s = syncStore([srcEvent("W1", "Standup", 1)])
    _ = try! syncRun(s)
    let dup = syncedCopies(s)[0]
    s.eventList.append(EventInfo.fixture(id: "dupe", title: dup.title, calendar: dup.calendar, calendarId: dup.calendarId,
                                         start: dup.start, end: dup.end, url: dup.url)) // same marker
    c.eq(syncedCopies(s).count, 2, "two copies share the same marker")
    _ = try! syncRun(s)
    c.eq(syncedCopies(s).count, 1, "sync converges duplicate markers back to one copy")
}

do {
    // a time-zone-only source change is detected and synced.
    let tzEvent: (String) -> EventInfo = { tz in
        EventInfo.fixture(id: "W1", title: "Call", calendar: "Work", calendarId: "cal-work",
                          start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), timeZone: tz)
    }
    let s = syncStore([tzEvent("Asia/Seoul")])
    _ = try! syncRun(s)
    c.eq(syncedCopies(s)[0].timeZone, "Asia/Seoul", "copy carries the source time zone")
    s.eventList[0] = tzEvent("America/New_York")
    c.expect(try! syncRun(s).performed, "a time-zone-only change is detected")
    c.eq(syncedCopies(s)[0].timeZone, "America/New_York", "copy reflects the new time zone")
}

do {
    // "Account/*" selects every calendar in that account.
    let a1 = CalendarInfo.fixture(title: "Cal1", source: "Acct", calendarIdentifier: "c1")
    let a2 = CalendarInfo.fixture(title: "Cal2", source: "Acct", calendarIdentifier: "c2")
    let dst = CalendarInfo.fixture(title: "Dst", source: "Other", calendarIdentifier: "cd")
    let s = FakeCalendarStore(calendars: [a1, a2, dst], defaultCalendar: dst)
    s.eventList = [
        EventInfo.fixture(id: "E1", title: "One", calendar: "Cal1", calendarId: "c1", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "E2", title: "Two", calendar: "Cal2", calendarId: "c2", start: agToday.addingTimeInterval(3 * hour), end: agToday.addingTimeInterval(4 * hour)),
    ]
    _ = try! runSync(store: s, from: ["Acct/*"], to: "Dst", since: nil, until: nil, detail: .titleTimeLocation, noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: kstNow, timeZone: kst)
    let copies = s.events(in: DateInterval(start: agToday, end: agToday.addingTimeInterval(40 * day)), calendars: ["cd"])
    c.eq(copies.count, 2, "Account/* mirrors every calendar in the account")
    c.eq(Set(copies.map { $0.title }), ["One", "Two"], "both calendars in the account are copied")
}

// MARK: sync — recurring series collapse to one rule-bearing copy

@MainActor func recEvent(_ id: String, _ title: String, _ rule: RecurrenceRule, _ offsetHours: Double = 1) -> EventInfo {
    EventInfo.fixture(id: id, title: title, calendar: "Work", calendarId: "cal-work",
                      start: agToday.addingTimeInterval(offsetHours * hour),
                      end: agToday.addingTimeInterval((offsetHours + 1) * hour),
                      recurring: true, recurrenceRule: rule)
}

do {
    // RecurrenceRule round-trips through Codable.
    let rule = RecurrenceRule(frequency: .weekly, interval: 2, count: 10, daysOfWeek: [2, 4])
    let back = try! JSONDecoder().decode(RecurrenceRule.self, from: JSONEncoder().encode(rule))
    c.eq(back, rule, "RecurrenceRule round-trips through Codable")
}

do {
    // a recurring series copies as exactly ONE rule-bearing event, not per-occurrence.
    let daily = RecurrenceRule(frequency: .daily)
    let s = syncStore([recEvent("R1", "Standup", daily)])
    _ = try! syncRun(s)
    let copies = syncedCopies(s)
    c.eq(copies.count, 1, "recurring series → exactly one copy (no per-occurrence explosion)")
    c.expect(copies[0].recurring, "the copy is itself recurring")
    c.expect(copies[0].recurrenceRule == daily, "the recurrence rule is copied verbatim")
    c.eq(copies[0].title, "Standup", "recurring copy keeps the title")
    // idempotent re-sync
    let r2 = try! syncRun(s)
    c.expect(r2.output.contains("up to date"), "re-sync of a recurring series is a no-op")
    c.eq(syncedCopies(s).count, 1, "re-sync doesn't duplicate the recurring copy")
}

do {
    // recurring + single in one sync: recurring collapses to 1, single stays 1.
    let weekly = RecurrenceRule(frequency: .weekly, interval: 1, daysOfWeek: [2])
    let s = syncStore([recEvent("R1", "Weekly", weekly), srcEvent("S1", "One-off", 5)])
    _ = try! syncRun(s)
    let copies = syncedCopies(s)
    c.eq(copies.count, 2, "one recurring + one single → two copies")
    c.eq(copies.filter { $0.recurring }.count, 1, "exactly one recurring copy (the whole series)")
    c.eq(copies.filter { !$0.recurring }.count, 1, "the single event still copies as a single")
    c.expect(copies.first { $0.recurring }?.recurrenceRule == weekly, "the weekly rule is carried")
}

do {
    // a source recurrence-rule change updates the copy in place, no duplicate.
    let s = syncStore([recEvent("R1", "Rec", RecurrenceRule(frequency: .daily))])
    _ = try! syncRun(s)
    s.eventList[0] = recEvent("R1", "Rec", RecurrenceRule(frequency: .weekly, daysOfWeek: [2]))
    let r = try! syncRun(s)
    c.expect(r.performed, "a changed recurrence rule is detected")
    c.eq(syncedCopies(s).count, 1, "rule change updates in place, no duplicate")
    c.expect(syncedCopies(s)[0].recurrenceRule?.frequency == .weekly, "the copy's rule reflects the change")
}

do {
    // RecurrenceRule normalizes in init: byday order-independent for equality,
    // and count wins over until (mutually exclusive).
    c.eq(RecurrenceRule(frequency: .weekly, daysOfWeek: [4, 2, 6]),
         RecurrenceRule(frequency: .weekly, daysOfWeek: [2, 6, 4]),
         "daysOfWeek order doesn't affect equality (sorted in init)")
    c.eq(RecurrenceRule(frequency: .weekly, daysOfWeek: [4, 2]).daysOfWeek, [2, 4],
         "daysOfWeek is stored sorted")
    let both = RecurrenceRule(frequency: .daily, until: agToday, count: 5)
    c.expect(both.until == nil && both.count == 5, "count wins: until is cleared when count is set")
}

do {
    // a recurring UPDATE routes the whole series (.futureEvents), not one occurrence.
    let s = syncStore([recEvent("R1", "Rec", RecurrenceRule(frequency: .daily))])
    _ = try! syncRun(s)
    s.eventList[0] = recEvent("R1", "Rec", RecurrenceRule(frequency: .weekly, daysOfWeek: [2]))
    _ = try! syncRun(s)
    c.eq(s.lastSpan, .futureEvents, "recurring update routes span .futureEvents (whole series)")
}

do {
    // a recurring mirror-DELETE routes the whole series (.futureEvents).
    let s = syncStore([recEvent("R1", "Rec", RecurrenceRule(frequency: .daily))])
    _ = try! syncRun(s)
    s.eventList.removeAll { $0.id == "R1" } // source series gone; the copy (fake id) remains
    _ = try! syncRun(s)
    c.eq(s.lastSpan, .futureEvents, "recurring mirror-delete routes span .futureEvents")
    c.eq(syncedCopies(s).count, 0, "recurring copy removed once its series is gone")
}

do {
    // a single event's update/delete still route .thisEvent.
    let s = syncStore([srcEvent("S1", "One", 1)])
    _ = try! syncRun(s)
    s.eventList[0] = srcEvent("S1", "One EDITED", 1)
    _ = try! syncRun(s)
    c.eq(s.lastSpan, .thisEvent, "single-event update routes span .thisEvent")
    s.eventList.removeAll { $0.id == "S1" }
    _ = try! syncRun(s)
    c.eq(s.lastSpan, .thisEvent, "single-event mirror-delete routes span .thisEvent")
}

// MARK: sync — reflect occurrences cancelled at the source

do {
    // occurrencesToCancel: target dates absent from source are the cancellations.
    let d1 = agToday.addingTimeInterval(day), d2 = agToday.addingTimeInterval(2 * day), d3 = agToday.addingTimeInterval(3 * day)
    c.eq(occurrencesToCancel(sourceDates: [d1, d3], targetDates: [d1, d2, d3]).map { Int($0.timeIntervalSinceReferenceDate.rounded()) },
         [Int(d2.timeIntervalSinceReferenceDate.rounded())], "cancel = target − source (by date)")
    c.eq(occurrencesToCancel(sourceDates: [], targetDates: [d1, d2]).count, 2, "empty source → every target date cancels")
    c.eq(occurrencesToCancel(sourceDates: [d1, d2, d3], targetDates: [d1, d2]).count, 0, "target ⊆ source → nothing cancels")
    c.eq(occurrencesToCancel(sourceDates: [d1.addingTimeInterval(0.4)], targetDates: [d1]).count, 0, "sub-second diffs aren't cancellations")
}

do {
    // Fake seriesOccurrences / cancelOccurrence plumbing: window filter, remove, idempotent.
    let s = syncStore([])
    let d1 = agToday.addingTimeInterval(day), d2 = agToday.addingTimeInterval(2 * day), far = agToday.addingTimeInterval(90 * day)
    s.seriesOccurrenceDates["X"] = [d1, d2, far]
    let win = DateInterval(start: agToday, end: agToday.addingTimeInterval(30 * day))
    c.eq(s.seriesOccurrences(id: "X", in: win).count, 2, "seriesOccurrences filters to the window")
    try! s.cancelOccurrence(id: "X", occurrence: d2)
    c.expect(!s.seriesOccurrences(id: "X", in: win).contains(d2), "cancelOccurrence removes the occurrence")
    try! s.cancelOccurrence(id: "X", occurrence: d2)
    c.eq(s.seriesOccurrences(id: "X", in: win).count, 1, "cancelling an already-gone occurrence is a no-op")
}

do {
    // occurrence handle round-trips; email-like / plain ids are not handles.
    let d = agToday.addingTimeInterval(day)
    let h = Output.occurrenceHandle(id: "S1", start: d)
    c.eq(Output.parseOccurrenceHandle(h)?.id, "S1", "occurrence handle round-trips id")
    c.expect(Output.parseOccurrenceHandle(h).map { abs($0.start.timeIntervalSince(d)) < 1 } ?? false,
             "occurrence handle round-trips start")
    c.expect(Output.parseOccurrenceHandle("abc@example.com") == nil, "email-like id is not an occurrence handle")
    c.expect(Output.parseOccurrenceHandle("plainid") == nil, "plain id → nil")
    c.expect(Output.parseOccurrenceHandle("R@1.5") == nil, "non-integer epoch → not a handle")
    c.expect(Output.parseOccurrenceHandle("R@1e3") == nil, "scientific epoch → not a handle")
    c.expect(Output.parseOccurrenceHandle("@123") == nil, "empty id → not a handle")
}

do {
    // rm <id>@<epoch> cancels just that occurrence (EXDATE), leaving the rest.
    let s = syncStore([EventInfo.fixture(id: "R", title: "Weekly", calendar: "Work", calendarId: "cal-work",
                                         start: agToday.addingTimeInterval(day), end: agToday.addingTimeInterval(day + hour),
                                         recurring: true)])
    let d1 = agToday.addingTimeInterval(day), d2 = agToday.addingTimeInterval(2 * day)
    s.seriesOccurrenceDates["R"] = [d1, d2]
    let win = DateInterval(start: agToday, end: agToday.addingTimeInterval(30 * day))
    _ = try! runRm(store: s, id: Output.occurrenceHandle(id: "R", start: d2),
                   allOccurrences: false, json: false, dryRun: false, confirm: AutoYes(), timeZone: kst)
    c.expect(!s.seriesOccurrences(id: "R", in: win).contains(d2), "rm <id>@<epoch> cancels that occurrence")
    c.expect(s.seriesOccurrences(id: "R", in: win).contains(d1), "other occurrences of the series remain")
    // json contract: rm <handle> --json emits NDJSON, not plain text.
    let j = try! runRm(store: s, id: Output.occurrenceHandle(id: "R", start: d1),
                       allOccurrences: false, json: true, dryRun: true, confirm: AutoYes(), timeZone: kst)
    if case .dryRun(let out) = j {
        c.expect(out.hasPrefix("{") && out.contains("\"cancelled\""), "rm <handle> --json emits NDJSON")
    } else { c.expect(false, "occurrence rm --json --dry-run returns .dryRun") }
}

do {
    // end-to-end: a source series that dropped an occurrence gets that occurrence
    // cancelled on the copy too (reflecting the source-side cancellation).
    let s = syncStore([recEvent("R1", "Standup", RecurrenceRule(frequency: .daily))])
    _ = try! syncRun(s)                              // create the recurring copy
    let copyId = syncedCopies(s)[0].id
    let w1 = agToday.addingTimeInterval(day), w2 = agToday.addingTimeInterval(2 * day), w3 = agToday.addingTimeInterval(3 * day)
    s.seriesOccurrenceDates["R1"] = [w1, w3]         // source: w2 cancelled
    s.seriesOccurrenceDates[copyId] = [w1, w2, w3]   // copy still has all three
    let r = try! syncRun(s)                          // reconcile
    c.expect(r.output.contains("cancelled"), "reconcile reports a cancellation")
    let win = DateInterval(start: agToday, end: agToday.addingTimeInterval(30 * day))
    c.eq(s.seriesOccurrences(id: copyId, in: win).map { Int($0.timeIntervalSinceReferenceDate.rounded()) },
         [w1, w3].map { Int($0.timeIntervalSinceReferenceDate.rounded()) },
         "the copy's cancelled occurrence (w2) is removed to match the source")
    let r2 = try! syncRun(s)
    c.expect(r2.output.contains("up to date"), "re-sync after reconciliation is a no-op")
}

do {
    // seriesOccurrences is empty for a non-recurring / unseeded id (contract;
    // the real EKCalendarStore guards on hasRecurrenceRules).
    let s = syncStore([srcEvent("S1", "One-off", 1)])
    _ = try! syncRun(s)
    let win = DateInterval(start: agToday, end: agToday.addingTimeInterval(30 * day))
    c.eq(s.seriesOccurrences(id: "S1", in: win).count, 0, "seriesOccurrences empty for a non-recurring id")
}

do {
    // seriesOccurrences window is half-open [start, end): keep start, drop end.
    let s = syncStore([])
    let start = agToday, end = agToday.addingTimeInterval(10 * day)
    s.seriesOccurrenceDates["X"] = [start, end.addingTimeInterval(-day), end]
    let got = s.seriesOccurrences(id: "X", in: DateInterval(start: start, end: end))
    c.expect(got.contains(start), "occurrence at window.start is included")
    c.expect(!got.contains(end), "occurrence exactly at window.end is excluded (half-open)")
    c.eq(got.count, 2, "half-open window keeps start, drops the end boundary")
}

do {
    // an existing recurring copy UPDATED in the same sync still gets its
    // cancellations — the diff is recomputed after the update, not on stale dates.
    let s = syncStore([recEvent("R1", "Rec", RecurrenceRule(frequency: .daily))])
    _ = try! syncRun(s)                                  // create copy (daily)
    let copyId = syncedCopies(s)[0].id
    s.eventList[0] = recEvent("R1", "Rec", RecurrenceRule(frequency: .weekly, daysOfWeek: [2])) // rule change
    let w1 = agToday.addingTimeInterval(day), w2 = agToday.addingTimeInterval(2 * day), w3 = agToday.addingTimeInterval(3 * day)
    s.seriesOccurrenceDates["R1"] = [w1, w3]             // source dropped w2
    s.seriesOccurrenceDates[copyId] = [w1, w2, w3]
    let r = try! syncRun(s)
    c.expect(r.performed, "update + cancellation applied in one sync")
    c.expect(syncedCopies(s)[0].recurrenceRule?.frequency == .weekly, "the copy's rule was updated")
    c.eq(s.lastSpan, .futureEvents, "the recurring update routed .futureEvents")
    let win = DateInterval(start: agToday, end: agToday.addingTimeInterval(30 * day))
    c.expect(!s.seriesOccurrences(id: copyId, in: win).contains(w2), "cancellation still applied after the update")
}

// MARK: SyncStatus (shared last-sync record file)

do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccal-synctest-\(UUID().uuidString)/last-sync")
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    c.expect(SyncStatus.last(from: tmp) == nil, "SyncStatus: no file -> nil")

    SyncStatus.record(at: Date(timeIntervalSince1970: 1_700_000_000), summary: "synced: +3 ~2 -0", to: tmp)
    let r = SyncStatus.last(from: tmp)
    c.eq(r?.summary, "synced: +3 ~2 -0", "SyncStatus: round-trips the summary")
    c.expect(r.map { abs($0.date.timeIntervalSince1970 - 1_700_000_000) < 1 } ?? false,
             "SyncStatus: round-trips the timestamp")

    SyncStatus.record(at: Date(timeIntervalSince1970: 1_700_000_050), summary: "a\nb", to: tmp)
    c.eq(SyncStatus.last(from: tmp)?.summary, "a\nb", "SyncStatus: summary keeps embedded newlines")

    try? "not-a-number\nx".write(to: tmp, atomically: true, encoding: .utf8)
    c.expect(SyncStatus.last(from: tmp) == nil, "SyncStatus: unparsable timestamp -> nil")

    try? "".write(to: tmp, atomically: true, encoding: .utf8)
    c.expect(SyncStatus.last(from: tmp) == nil, "SyncStatus: empty file -> nil")
}

// MARK: AppVersion (symlink-robust bundle version lookup)

do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccal-vertest-\(UUID().uuidString)")
    let contents = root.appendingPathComponent("maccal.app/Contents")
    let exe = contents.appendingPathComponent("MacOS/maccal")
    let info = contents.appendingPathComponent("Info.plist")
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: exe.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! Data().write(to: exe)

    func writePlist(_ version: String) {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try! data.write(to: info)
    }

    c.expect(AppVersion.infoPlistVersion(forExecutable: exe) == nil,
             "AppVersion: no Info.plist -> nil")
    c.expect(AppVersion.infoPlistVersion(forExecutable: nil) == nil,
             "AppVersion: nil executable -> nil")

    writePlist("9.9.9")
    c.eq(AppVersion.infoPlistVersion(forExecutable: exe), "9.9.9",
         "AppVersion: reads CFBundleShortVersionString from the bundle's Info.plist")

    writePlist("dev")
    c.expect(AppVersion.infoPlistVersion(forExecutable: exe) == nil,
             "AppVersion: the build-time 'dev' placeholder is treated as absent")

    // A symlinked launcher (like Homebrew's bin/maccal) resolves to the same bundle.
    writePlist("9.9.9")
    let link = root.appendingPathComponent("maccal-link")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
    c.eq(AppVersion.infoPlistVersion(forExecutable: link.resolvingSymlinksInPath()), "9.9.9",
         "AppVersion: a symlinked launcher resolves to the bundle version")
}

// MARK: SyncAgent (menu-bar app's launchd job spec)

do {
    let argv = SyncAgent.argv(maccalPath: "/x/maccal", sources: ["A", "B/C"], target: "T", detail: .withNotes)
    c.eq(argv, ["/x/maccal", "sync", "--from", "A", "--from", "B/C", "--to", "T", "--notes", "--yes"],
         "argv: repeated --from, --to, --notes, trailing --yes")

    // Independent detail toggles: title on, location off, notes on.
    c.eq(SyncAgent.argv(maccalPath: "/x/maccal", sources: ["A"], target: "T", detail: [.title, .notes]),
         ["/x/maccal", "sync", "--from", "A", "--to", "T", "--no-location", "--notes", "--yes"],
         "argv: [.title,.notes] → --no-location --notes")

    let plain = SyncAgent.argv(maccalPath: "/x/maccal", sources: ["A"], target: "T", detail: .titleTimeLocation)
    c.eq(plain, ["/x/maccal", "sync", "--from", "A", "--to", "T", "--yes"],
         "argv: .titleTimeLocation adds neither flag")

    let plist = SyncAgent.launchdPlist(
        maccalPath: "/x/maccal", sources: ["A", "B/C"], target: "T", detail: .withNotes, intervalMinutes: 30)
    c.eq(plist["Label"] as? String, SyncAgent.label, "plist Label")
    c.eq(plist["StartInterval"] as? Int, 30 * 60, "plist StartInterval = minutes * 60")
    c.eq(plist["ProgramArguments"] as? [String],
         SyncAgent.argv(maccalPath: "/x/maccal", sources: ["A", "B/C"], target: "T", detail: .withNotes),
         "plist ProgramArguments == argv")
    c.expect(plist["RunAtLoad"] as? Bool == true, "plist RunAtLoad")

    // interval is clamped to a positive number of seconds
    let clamped = SyncAgent.launchdPlist(
        maccalPath: "/x/maccal", sources: ["A"], target: "T", detail: .titleTimeLocation, intervalMinutes: 0)
    c.eq(clamped["StartInterval"] as? Int, 60, "plist StartInterval clamps 0 → 60s")
}

// MARK: color — ANSI output (opt-in via `color:`)

do {
    // paint: off passes through, on wraps, multiple styles stack in order.
    c.eq(Output.paint("x", .cyan, enabled: false), "x", "paint off → unchanged")
    c.eq(Output.paint("x", .cyan, enabled: true), "\u{001B}[36mx\u{001B}[0m", "paint cyan wraps")
    c.eq(Output.paint("x", .bold, .red, enabled: true), "\u{001B}[1m\u{001B}[31mx\u{001B}[0m", "paint stacks styles")
    c.eq(Output.paint("x", enabled: true), "x", "paint with no styles → unchanged")

    // colorSwatch: truecolor dot + hex, robust to off / bad input.
    c.eq(Output.colorSwatch("#FF0000", enabled: true), "\u{001B}[38;2;255;0;0m●\u{001B}[0m #FF0000", "swatch truecolor")
    c.eq(Output.colorSwatch("#FF0000", enabled: false), "#FF0000", "swatch off → hex")
    c.eq(Output.colorSwatch("nope", enabled: true), "nope", "swatch bad hex → unchanged")

    // stripANSI round-trips paint and leaves plain text alone.
    c.eq(Output.stripANSI(Output.paint("hi", .cyan, .bold, enabled: true)), "hi", "stripANSI removes codes")
    c.eq(Output.stripANSI("plain"), "plain", "stripANSI leaves plain text")

    // command output: color on emits ANSI, off is plain, JSON stays plain.
    let ev = EventInfo.fixture(id: "C1", title: "Standup", start: kstNow, end: kstNow.addingTimeInterval(1800))
    let store = FakeCalendarStore(events: [ev])
    let aColor = try! runAgenda(store: store, json: false, color: true, now: kstNow, timeZone: kst)
    let aPlain = try! runAgenda(store: store, json: false, color: false, now: kstNow, timeZone: kst)
    c.expect(aColor.contains("\u{001B}["), "agenda color:true emits ANSI")
    c.expect(!aPlain.contains("\u{001B}["), "agenda color:false is plain")
    c.eq(Output.stripANSI(aColor), aPlain, "agenda colored strips back to the plain output")
    c.expect(!(try! runAgenda(store: store, json: true, color: true, now: kstNow, timeZone: kst)).contains("\u{001B}["),
             "agenda --json ignores color (NDJSON stays plain)")

    let sColor = try! runSearch(store: store, query: "Standup", json: false, color: true, now: kstNow, timeZone: kst)
    c.expect(sColor.contains("\u{001B}["), "search color:true emits ANSI")

    // calendars: rw green + a truecolor swatch derived from the hex.
    let cstore = FakeCalendarStore(calendars: [.fixture(title: "Work", writable: true, color: "#00FF00")])
    let calColor = runCalendars(store: cstore, json: false, color: true)
    c.expect(calColor.contains("\u{001B}[32m"), "calendars color → rw green")
    c.expect(calColor.contains("38;2;0;255;0"), "calendars color → truecolor swatch from hex")
    c.expect(!runCalendars(store: cstore, json: false, color: false).contains("\u{001B}["), "calendars color:false plain")

    // show: dim labels.
    let shColor = runShow(store: store, id: "C1", json: false, color: true, timeZone: kst).output
    c.expect(shColor.contains("\u{001B}[2m"), "show color → dim labels")
    c.expect(!runShow(store: store, id: "C1", json: false, color: false, timeZone: kst).output.contains("\u{001B}["),
             "show color:false plain")
}

// MARK: ICS export/import (iCalendar round-trip)

do {
    let start = kstCal.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 10, minute: 30))!
    let e = EventInfo.fixture(id: "E1", title: "Lunch; with, Sam", calendar: "Work", calendarId: "cal-work",
                              start: start, end: start.addingTimeInterval(3600),
                              location: "Room 4F", notes: "line1\nline2", url: "https://x.example/a")
    let ics = ICS.export(e, now: kstNow, timeZone: kst)
    c.expect(ics.contains("BEGIN:VEVENT") && ics.contains("END:VCALENDAR"), "export wraps a VEVENT in a VCALENDAR")
    c.expect(ics.contains("SUMMARY:Lunch\\; with\\, Sam"), "export escapes ; and ,")
    let back = ICS.parse(ics, timeZone: kst)
    c.eq(back.count, 1, "one VEVENT → one draft")
    c.eq(back.first?.title, "Lunch; with, Sam", "title round-trips (unescaped)")
    c.expect(back.first.map { abs($0.start.timeIntervalSince(start)) < 1 } ?? false, "start round-trips via UTC")
    c.eq(back.first?.location, "Room 4F", "location round-trips")
    c.eq(back.first?.notes, "line1\nline2", "notes round-trip incl. newline")
    c.eq(back.first?.url, "https://x.example/a", "url round-trips")

    // all-day round-trips as VALUE=DATE (local day)
    let day = kstCal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
    let ad = EventInfo.fixture(id: "A", title: "PTO", start: day, end: kstCal.date(byAdding: .day, value: 1, to: day)!, allDay: true)
    let adIcs = ICS.export(ad, now: kstNow, timeZone: kst)
    c.expect(adIcs.contains("DTSTART;VALUE=DATE:20260701"), "all-day exports as VALUE=DATE")
    c.expect(ICS.parse(adIcs, timeZone: kst).first?.allDay == true, "all-day round-trips")

    // runImport creates the parsed drafts; empty input → error
    let s = syncStore([])
    c.expect(try! runImport(store: s, drafts: back, calendar: "Personal", dryRun: false, confirm: AutoYes(), timeZone: kst).performed,
             "import creates the parsed events")
    c.eq(caught { _ = try runImport(store: s, drafts: [], calendar: nil, dryRun: false, confirm: AutoYes(), timeZone: kst) } as? WriteValidationError,
         .noEventsToImport, "empty import → noEventsToImport")

    // RFC 5545 property names (and BEGIN/END) are case-insensitive.
    c.eq(ICS.parse("begin:vevent\r\nSUMMARY:lower\r\nDTSTART:20260101T000000Z\r\nend:vevent", timeZone: kst).first?.title,
         "lower", "lowercase BEGIN/END still parse")
}

// MARK: free — open slots within work hours

do {
    let dayStart = kstCal.startOfDay(for: kstNow)
    let win = DateInterval(start: dayStart, end: kstCal.date(byAdding: .day, value: 1, to: dayStart)!)
    let mtg = EventInfo.fixture(id: "B", title: "Mtg", calendar: "Work",
        start: kstCal.date(bySettingHour: 10, minute: 0, second: 0, of: dayStart)!,
        end: kstCal.date(bySettingHour: 11, minute: 0, second: 0, of: dayStart)!)
    let s = FakeCalendarStore(events: [mtg])
    // 09–18 work day minus a 10–11 meeting → 09–10 (60m) and 11–18 (420m).
    let slots = runFree(store: s, window: win, minDuration: 3600, workStartHour: 9, workEndHour: 18, json: true, timeZone: kst)
        .split(separator: "\n").map(String.init)
    c.eq(slots.count, 2, "two free slots around a midday meeting")
    c.expect(slots.first?.contains("\"minutes\":60") ?? false, "morning slot is 60 min (09–10)")
    c.expect(slots.last?.contains("\"minutes\":420") ?? false, "afternoon slot is 420 min (11–18)")
    // a 2h minimum drops the 1h morning gap
    let big = runFree(store: s, window: win, minDuration: 7200, workStartHour: 9, workEndHour: 18, json: true, timeZone: kst)
        .split(separator: "\n").filter { !$0.isEmpty }
    c.eq(big.count, 1, "min 2h keeps only the afternoon slot")
    // an availability=free event doesn't count as busy
    let freeEv = EventInfo.fixture(id: "F", title: "OOO", calendar: "Work",
        start: kstCal.date(bySettingHour: 13, minute: 0, second: 0, of: dayStart)!,
        end: kstCal.date(bySettingHour: 14, minute: 0, second: 0, of: dayStart)!, availability: "free")
    let full = runFree(store: FakeCalendarStore(events: [freeEv]), window: win, minDuration: 3600,
                       workStartHour: 9, workEndHour: 18, json: true, timeZone: kst)
        .split(separator: "\n").filter { !$0.isEmpty }
    c.eq(full.count, 1, "an availability=free event doesn't split the day")
    c.expect(full.first?.contains("\"minutes\":540") ?? false, "whole 09–18 stays free (540 min)")
    // work-end 24 reaches midnight (bySettingHour:24 would be nil)
    let late = runFree(store: FakeCalendarStore(events: []), window: win, minDuration: 3600, workStartHour: 9, workEndHour: 24, json: true, timeZone: kst)
        .split(separator: "\n").filter { !$0.isEmpty }
    c.eq(late.count, 1, "work-end 24 → one slot to midnight")
    c.expect(late.first?.contains("\"minutes\":900") ?? false, "09–24 = 900 min")
    // a fully-booked day → empty text (like agenda/search), not a message
    let booked = EventInfo.fixture(id: "X", title: "busy", calendar: "Work",
        start: kstCal.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart)!,
        end: kstCal.date(bySettingHour: 18, minute: 0, second: 0, of: dayStart)!)
    c.eq(runFree(store: FakeCalendarStore(events: [booked]), window: win, minDuration: 3600, workStartHour: 9, workEndHour: 18, json: false, timeZone: kst),
         "", "a fully-booked day → empty text (scripting-friendly)")
}

// MARK: - output: display width + aligned table (Output.displayWidth / table)
do {
    c.eq(Output.displayWidth("abc"), 3, "ascii width = count")
    c.eq(Output.displayWidth("대한민국"), 8, "Hangul counts 2 per char")
    c.eq(Output.displayWidth("일본"), 4, "kanji counts 2 per char")
    c.eq(Output.displayWidth("A가B"), 4, "mixed ascii(1)+CJK(2)")
    c.eq(Output.displayWidth(Output.paint("hi", .red, enabled: true)), 2, "ANSI escapes are zero width")
    c.eq(Output.displayWidth("é"), 1, "precomposed accent width 1")
    c.eq(Output.displayWidth("e\u{0301}"), 1, "combining mark adds 0 width")
    c.eq(Output.displayWidth("●"), 1, "swatch dot width 1")

    // Aligned columns line up on DISPLAY width (CJK-aware), last cell unpadded.
    let rows = [["가나", "A"], ["ab", "B"]]
    let lines = Output.table(rows, aligned: true, gutter: 2).split(separator: "\n").map(String.init)
    func prefixWidth(_ line: String, before cell: String) -> Int {
        guard let r = line.range(of: cell, options: .backwards) else { return -1 }
        return Output.displayWidth(String(line[line.startIndex..<r.lowerBound]))
    }
    c.eq(prefixWidth(lines[0], before: "A"), prefixWidth(lines[1], before: "B"), "columns align on display width")
    c.eq(prefixWidth(lines[0], before: "A"), 6, "col0 width(4) + gutter(2)")
    c.expect(!lines[0].hasSuffix(" "), "last cell is not right-padded")
    c.eq(Output.table(rows, aligned: false), "가나\tA\nab\tB\n", "unaligned = raw TSV")
    c.eq(Output.table([], aligned: true), "", "empty aligned table → empty")
    c.eq(Output.table([], aligned: false), "", "empty tsv → empty")

    c.eq(Output.colorDot("#FF0000"), "\u{001B}[38;2;255;0;0m●\u{001B}[0m", "colorDot → truecolor dot")
    c.eq(Output.colorDot("bogus"), "●", "colorDot invalid hex → plain dot")
}

// MARK: - config (Config / ConfigLoader)
do {
    let empty = try! ConfigLoader.parse(Data("{}".utf8))
    c.eq(empty.hiddenCalendars.count, 0, "empty config → no hidden")
    c.expect(empty.defaultCalendar == nil, "empty config → no default calendar")

    let partial = try! ConfigLoader.parse(Data(#"{"hiddenCalendars":["Birthdays","cal-xyz"],"unknownKey":42}"#.utf8))
    c.eq(partial.hiddenCalendars.count, 2, "hiddenCalendars parsed; unknown key ignored")
    c.expect(partial.isHidden(title: "birthdays", identifier: "zzz"), "isHidden matches title case-insensitively")
    c.expect(partial.isHidden(title: "zzz", identifier: "CAL-XYZ"), "isHidden matches identifier case-insensitively")
    c.expect(!partial.isHidden(title: "Work", identifier: "w"), "non-hidden calendar not matched")

    let always = try! ConfigLoader.parse(Data(#"{"color":"always"}"#.utf8))
    c.expect(always.useColor(isTTY: false, flagNoColor: false, envNoColor: false), "color=always → on even off-TTY")
    c.expect(!always.useColor(isTTY: false, flagNoColor: true, envNoColor: false), "--no-color beats color=always")
    c.expect(!always.useColor(isTTY: true, flagNoColor: false, envNoColor: true), "NO_COLOR beats color=always")
    let never = try! ConfigLoader.parse(Data(#"{"color":"never"}"#.utf8))
    c.expect(!never.useColor(isTTY: true, flagNoColor: false, envNoColor: false), "color=never → off even on TTY")
    c.expect(Config().useColor(isTTY: true, flagNoColor: false, envNoColor: false), "auto → on for TTY")
    c.expect(!Config().useColor(isTTY: false, flagNoColor: false, envNoColor: false), "auto → off off-TTY")

    c.eq(ConfigLoader.path(environment: ["MACCAL_CONFIG": "/x/c.json"], home: "/h"), "/x/c.json", "MACCAL_CONFIG wins")
    c.eq(ConfigLoader.path(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/h"), "/xdg/maccal/config.json", "XDG_CONFIG_HOME next")
    c.eq(ConfigLoader.path(environment: [:], home: "/h"), "/h/.config/maccal/config.json", "default ~/.config/maccal")

    var threw = false
    do { _ = try ConfigLoader.parse(Data("not json".utf8)) } catch { threw = true }
    c.expect(threw, "malformed config throws")
    c.eq(try! ConfigLoader.load(path: "/nonexistent/maccal/config.json").hiddenCalendars.count, 0, "missing file → defaults, no throw")
}

// MARK: - hide-list (calendars / agenda / search / free)
do {
    let cals = FakeCalendarStore(calendars: [
        .fixture(title: "Work", source: "corp", calendarIdentifier: "w"),
        .fixture(title: "Birthdays", source: "Other", writable: false, calendarIdentifier: "b"),
    ])
    let visible = runCalendars(store: cals, json: false, hiddenCalendars: ["Birthdays"])
    c.expect(!visible.contains("Birthdays"), "calendars hides hidden by title")
    c.expect(visible.contains("Work"), "calendars keeps visible")
    c.expect(runCalendars(store: cals, json: false, hiddenCalendars: ["Birthdays"], showAll: true).contains("Birthdays"), "--all shows hidden")
    c.expect(!runCalendars(store: cals, json: false, hiddenCalendars: ["b"]).contains("Birthdays"), "calendars hides hidden by identifier")
    c.expect(!runCalendars(store: cals, json: true, hiddenCalendars: ["Birthdays"]).contains("Birthdays"), "hide-list applies to --json too")

    let evs = [
        EventInfo.fixture(id: "e1", title: "Standup", calendar: "Work", calendarId: "w",
                          start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
        EventInfo.fixture(id: "e2", title: "Bday", calendar: "Birthdays", calendarId: "b",
                          start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour)),
    ]
    let es = FakeCalendarStore(events: evs)
    let ag = try! runAgenda(store: es, json: false, hiddenCalendars: ["Birthdays"], now: kstNow, timeZone: kst)
    c.expect(ag.contains("Standup") && !ag.contains("Bday"), "agenda excludes hidden-calendar events")
    c.expect(try! runAgenda(store: es, json: false, hiddenCalendars: ["Birthdays"], showAll: true, now: kstNow, timeZone: kst).contains("Bday"), "agenda --all includes hidden")
    c.expect(try! runAgenda(store: es, json: false, calendars: ["Birthdays"], hiddenCalendars: ["Birthdays"], now: kstNow, timeZone: kst).contains("Bday"), "explicit --calendar overrides hide-list")
    let se = try! runSearch(store: es, query: "", json: false, hiddenCalendars: ["Birthdays"], now: kstNow, timeZone: kst)
    c.expect(se.contains("Standup") && !se.contains("Bday"), "search excludes hidden-calendar events")
}

// MARK: - hide-list matcher parity (Config.isHidden ↔ EventInfo.matchesCalendar)
do {
    // Both matchers must fold case identically so `calendars` and agenda/search/free
    // agree on the hidden set. Title = locale-aware, identifier = plain.
    let cases: [(String, String, [String], Bool)] = [
        ("Work", "w", ["work"], true),          // title match, case-insensitive
        ("Work", "w", ["w"], true),             // identifier match
        ("Work", "w", ["OTHER"], false),        // no match
        ("대한민국의 휴일", "k", ["대한민국의 휴일"], true), // CJK title match
    ]
    for (t, i, h, want) in cases {
        let byConfig = Config(hiddenCalendars: h).isHidden(title: t, identifier: i)
        let byEvent = EventInfo.fixture(id: "e", calendar: t, calendarId: i, start: agToday, end: agToday.addingTimeInterval(hour)).matchesCalendar(h)
        c.eq(byConfig, want, "isHidden(\(t)/\(i) in \(h)) == \(want)")
        c.eq(byConfig, byEvent, "isHidden and matchesCalendar agree for \(t)/\(i) in \(h)")
    }
}

// MARK: - JSON handle parity (agenda/search/show gain a `handle`)
do {
    let start = agToday.addingTimeInterval(hour)
    let rule = RecurrenceRule(frequency: .weekly, interval: 1, daysOfWeek: [2, 4])
    let rec = EventInfo.fixture(id: "R1", title: "Weekly", calendar: "Work", start: start, end: start + 1800, recurring: true, recurrenceRule: rule)
    let one = EventInfo.fixture(id: "S1", title: "Single", calendar: "Work", start: start, end: start + 1800)
    let js = try! runAgenda(store: FakeCalendarStore(events: [rec, one]), json: true, now: kstNow, timeZone: kst)
    let objs = js.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    let byId = Dictionary(objs.map { ($0["id"] as! String, $0) }, uniquingKeysWith: { a, _ in a })
    c.expect((byId["R1"]?["handle"] as? String) == Output.occurrenceHandle(id: "R1", start: start), "recurring json handle = id@epoch")
    c.expect((byId["S1"]?["handle"] as? String) == "S1", "non-recurring json handle = id")
    let txt = try! runAgenda(store: FakeCalendarStore(events: [rec]), json: false, now: kstNow, timeZone: kst)
    c.expect(txt.contains(Output.occurrenceHandle(id: "R1", start: start)), "recurring text last column = id@epoch")
}

// MARK: - calendars color A-design (leading dot, hex dropped, sanitized)
do {
    let cals = FakeCalendarStore(calendars: [.fixture(title: "Work", source: "corp", color: "#4986E7")])
    let colored = runCalendars(store: cals, json: false, color: true)
    c.expect(colored.contains("\u{001B}[38;2;73;134;231m●"), "color on → leading truecolor dot")
    c.expect(!colored.contains("#4986E7"), "hex removed from human output")
    let plain = runCalendars(store: cals, json: false, color: false)
    c.expect(!plain.contains("●") && !plain.contains("#4986E7"), "color off → no dot, no hex")
    c.expect(runCalendars(store: cals, json: true).contains("#4986E7"), "json keeps the color hex")

    let dirty = FakeCalendarStore(calendars: [.fixture(title: "Team\tPlans", source: "corp\nX")])
    let dl = runCalendars(store: dirty, json: false).split(separator: "\n")
    c.eq(dl.count, 1, "calendars: newline in a name doesn't split the row")
    c.eq(dl[0].split(separator: "\t", omittingEmptySubsequences: false).count, 4, "calendars: tab in title doesn't add a column")
}

// MARK: - show fidelity (id, recurrence summary, all-day span, sanitize, json handle)
do {
    let start = agToday.addingTimeInterval(hour)
    let rule = RecurrenceRule(frequency: .weekly, interval: 2, daysOfWeek: [2, 4])
    let rec = EventInfo.fixture(id: "R9", title: "Sync", calendar: "Work", start: start, end: start + 1800, recurring: true, recurrenceRule: rule)
    let store = FakeCalendarStore(events: [rec])
    let out = runShow(store: store, id: "R9", json: false, timeZone: kst).output
    c.expect(out.contains("Id:"), "show includes an Id row")
    c.expect(out.contains(Output.occurrenceHandle(id: "R9", start: start)), "show Id = handle")
    c.expect(out.contains("every 2 weeks on Mon, Wed"), "show renders recurrence summary")
    c.expect(runShow(store: store, id: "R9", json: true, timeZone: kst).output.contains("\"handle\""), "show --json includes handle")

    var adCal = Calendar(identifier: .gregorian); adCal.timeZone = kst
    let d0 = adCal.startOfDay(for: agToday)
    let allDay = EventInfo.fixture(id: "AD", title: "PTO", calendar: "Work", start: d0, end: adCal.date(byAdding: .day, value: 3, to: d0)!, allDay: true)
    c.expect(runShow(store: FakeCalendarStore(events: [allDay]), id: "AD", json: false, timeZone: kst).output.contains("—"), "all-day multi-day shows a date range")

    let dirty = EventInfo.fixture(id: "D", title: "X", calendar: "Work", start: start, end: start + 1800, location: "Room\n4F")
    c.expect(runShow(store: FakeCalendarStore(events: [dirty]), id: "D", json: false, timeZone: kst).output.contains("Room 4F"), "show sanitizes a newline in location")
}

// MARK: - import --json
do {
    let draft = EventDraft(title: "Imported", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour),
                           allDay: false, calendar: "Work", timeZoneId: nil, location: "", notes: "", url: "", availability: "busy", recurrenceRule: nil)
    let store = FakeCalendarStore(calendars: [.fixture(title: "Work")], defaultCalendar: .fixture(title: "Work"))
    if case .dryRun(let s) = try! runImport(store: store, drafts: [draft], calendar: nil, json: true, dryRun: true, confirm: AutoYes(), timeZone: kst) {
        c.expect(s.contains("\"action\":\"would-import\""), "import --json --dry-run emits plan JSON")
    } else { c.expect(false, "import dry-run returns .dryRun") }
    if case .wrote(let s) = try! runImport(store: store, drafts: [draft], calendar: nil, json: true, dryRun: false, confirm: AutoYes(), timeZone: kst) {
        c.expect(s.contains("Imported") && s.contains("\"handle\""), "import --json echoes created events with handle")
    } else { c.expect(false, "import returns .wrote") }
}

// MARK: - bug-hunt regressions (correctness fixes)
do {
    // Multi-word date forms must parse as date-only for --start/--end (used to be
    // mis-split at the first space into a bogus "time" and rejected).
    for form in ["next monday", "last friday", "this wednesday", "next week", "in 3 days", "in 2 weeks", "friday"] {
        let r = try? DateTime.parse(form, now: kstNow, timeZone: kst)
        c.expect(r != nil && r!.isDateOnly, "DateTime.parse '\(form)' → date-only (not mis-split)")
    }
    // A multi-word date + clock splits at the LAST space.
    if let r = try? DateTime.parse("next monday 14:30", now: kstNow, timeZone: kst) {
        c.expect(!r.isDateOnly, "'next monday 14:30' is timed")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = kst
        let hm = cal.dateComponents([.hour, .minute], from: r.date)
        c.expect(hm.hour == 14 && hm.minute == 30, "'next monday 14:30' clock = 14:30")
    } else { c.expect(false, "'next monday 14:30' parses") }
    c.expect((try? DateTime.parse("2026-07-01 09:00", now: kstNow, timeZone: kst))?.isDateOnly == false, "ISO date + space time is timed")
    c.expect((try? DateTime.parse("2026-07-01", now: kstNow, timeZone: kst))?.isDateOnly == true, "ISO date only is date-only")
}

do {
    // htmlToPlain must not eat real text between a literal '<' and the next '>'.
    c.eq(Output.htmlToPlain("a < b and 5 < 10"), "a < b and 5 < 10", "literal '<' in prose is kept")
    c.eq(Output.htmlToPlain("<p>Hi</p>"), "Hi", "real <p> tag stripped")
    c.eq(Output.htmlToPlain("x <b>bold</b> y"), "x bold y", "real inline tag stripped")
    c.expect(Output.htmlToPlain("if x < y then<br>z").contains("if x < y then"), "text before a lone '<' survives a real <br>")
    // HTML comments and declarations (common in Google/Exchange notes) are stripped.
    let commented = Output.htmlToPlain("Meeting <!-- internal: cancel? --> at 3pm")
    c.expect(!commented.contains("<!--") && !commented.contains("cancel"), "HTML comment (and its body) stripped")
    c.eq(Output.htmlToPlain("<!DOCTYPE html><p>Body</p>"), "Body", "<!DOCTYPE …> declaration stripped")
}

do {
    // ICS export: CR/CRLF/LF in a TEXT value all become the escaped \n (no raw CR).
    let ev = EventInfo.fixture(id: "e", calendar: "W", start: agToday.addingTimeInterval(hour), end: agToday.addingTimeInterval(2 * hour), notes: "line1\r\nline2\rline3")
    let ics = ICS.export(ev, now: agToday, timeZone: kst)
    c.expect(ics.contains("DESCRIPTION:line1\\nline2\\nline3"), "escape normalizes CR/CRLF/LF to \\n")

    // ICS import: a TZID floating stamp is read in THAT zone, not the reader's.
    let text = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nSUMMARY:TZ\r\nDTSTART;TZID=America/New_York:20260701T090000\r\nDTEND;TZID=America/New_York:20260701T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    let drafts = ICS.parse(text, timeZone: kst)     // reader zone KST, but TZID says NY
    c.eq(drafts.count, 1, "one VEVENT parsed")
    if let d = drafts.first {
        var nyCal = Calendar(identifier: .gregorian); nyCal.timeZone = TimeZone(identifier: "America/New_York")!
        let hm = nyCal.dateComponents([.hour, .minute], from: d.start)
        c.expect(hm.hour == 9 && hm.minute == 0, "TZID start read as 09:00 America/New_York, not KST")
    }
}

do {
    // Import rejects degenerate/invalid drafts before writing (dry-run parity).
    let store = FakeCalendarStore(calendars: [.fixture(title: "W")], defaultCalendar: .fixture(title: "W"))
    var vc = Calendar(identifier: .gregorian); vc.timeZone = kst
    let d0 = vc.startOfDay(for: agToday)
    func imports(_ d: EventDraft) -> Bool {
        do { _ = try runImport(store: store, drafts: [d], calendar: nil, json: false, dryRun: true, confirm: AutoYes(), timeZone: kst); return true }
        catch { return false }
    }
    let endBeforeStart = EventDraft(title: "X", start: d0.addingTimeInterval(2 * hour), end: d0.addingTimeInterval(hour), allDay: false, calendar: "W", timeZoneId: nil, location: "", notes: "", url: "", availability: "busy", recurrenceRule: nil)
    c.expect(!imports(endBeforeStart), "import rejects end <= start")
    let allDayNotWhole = EventDraft(title: "X", start: d0.addingTimeInterval(hour), end: vc.date(byAdding: .day, value: 1, to: d0)!, allDay: true, calendar: "W", timeZoneId: nil, location: "", notes: "", url: "", availability: "busy", recurrenceRule: nil)
    c.expect(!imports(allDayNotWhole), "import rejects an all-day span not on whole days")
    let good = EventDraft(title: "X", start: d0, end: vc.date(byAdding: .day, value: 1, to: d0)!, allDay: true, calendar: "W", timeZoneId: nil, location: "", notes: "", url: "", availability: "busy", recurrenceRule: nil)
    c.expect(imports(good), "import accepts a whole-day all-day event")
}

do {
    // Edit: a sub-day --duration on an all-day event is rejected, not silently snapped.
    var vc = Calendar(identifier: .gregorian); vc.timeZone = kst
    let d0 = vc.startOfDay(for: agToday)
    let allDay = EventInfo.fixture(id: "AD", calendar: "W", start: d0, end: vc.date(byAdding: .day, value: 2, to: d0)!, allDay: true)
    let store = FakeCalendarStore(events: [allDay])
    func edits(duration: String?) -> Bool {
        do {
            _ = try runEdit(store: store, id: "AD", title: nil, start: nil, end: nil, duration: duration, tz: nil,
                            location: nil, notes: nil, url: nil, availability: nil, calendar: nil,
                            allOccurrences: false, json: false, dryRun: true, confirm: AutoYes(), now: kstNow, timeZone: kst)
            return true
        } catch { return false }
    }
    c.expect(!edits(duration: "90m"), "edit all-day rejects a sub-day --duration")
    c.expect(edits(duration: "2d"), "edit all-day accepts a whole-day --duration")
}

// MARK: - date styles + max config
do {
    var fc = Calendar(identifier: .gregorian); fc.timeZone = kst
    let d = fc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9, minute: 30))!
    let sameYear = fc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    let otherYear = fc.date(from: DateComponents(year: 2025, month: 1, day: 1))!
    c.eq(Output.formatInstant(d, style: .iso, timeZone: kst), "2026-07-06T09:30:00+09:00", "iso style unchanged")
    c.eq(Output.formatInstant(d, style: .readable, timeZone: kst), "2026-07-06 09:30", "readable = date + HH:MM")
    c.expect(Output.formatInstant(d, style: .friendly, now: sameYear, timeZone: kst).hasSuffix("Jul 6 09:30"), "friendly ends 'Jul 6 09:30'")
    c.eq(Output.formatInstant(d, style: .compact, now: sameYear, timeZone: kst), "Jul 6 09:30", "compact omits year within now's year")
    c.eq(Output.formatInstant(d, style: .compact, now: otherYear, timeZone: kst), "Jul 6 2026 09:30", "compact shows year across years")
    let day = fc.date(from: DateComponents(year: 2026, month: 8, day: 1))!
    c.eq(Output.formatDay(day, style: .readable, timeZone: kst), "2026-08-01", "readable all-day = plain date")
    c.eq(Output.formatDay(day, style: .compact, now: sameYear, timeZone: kst), "Aug 1", "compact all-day = month day")

    // agenda renders in the chosen style (window anchored so the event is in range)
    let ev = EventInfo.fixture(id: "S", calendar: "W", start: d, end: d.addingTimeInterval(1800))
    let ag = try! runAgenda(store: FakeCalendarStore(events: [ev]), json: false, dateStyle: .readable, now: fc.startOfDay(for: d), timeZone: kst)
    c.expect(ag.contains("2026-07-06 09:30") && !ag.contains("T09:30"), "agenda readable style in rows, no ISO 'T'")

    // config keys parse and are optional
    let cfg = try! ConfigLoader.parse(Data(#"{"dateFormat":"friendly","agendaMax":50,"searchMax":5}"#.utf8))
    c.eq(cfg.dateFormat, "friendly", "dateFormat parsed")
    c.eq(cfg.agendaMax, 50, "agendaMax parsed")
    c.eq(cfg.searchMax, 5, "searchMax parsed")
    let empty = try! ConfigLoader.parse(Data("{}".utf8))
    c.expect(empty.dateFormat == nil && empty.agendaMax == nil && empty.searchMax == nil, "new config keys default nil")
}

// Live EventKit round-trip — local only, needs a Calendar grant. CI omits the
// flag and runs the pure suite above. See Integration.swift.
if CommandLine.arguments.contains("--integration") {
    await runIntegrationChecks(c)
}

c.summary()
