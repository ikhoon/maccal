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
    c.expect(lines[0].contains("\trw\t"), "writable column rw")
    c.expect(lines[2].contains("\tro\t"), "read-only column ro")
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
    c.expect(capped.contains("(showing 3 of 5 — narrow filters if too many)"), "trailer shows M of N when capped")
    c.eq(capped.split(separator: "\n").filter { !$0.hasPrefix("(showing ") }.count, 3, "--max caps shown rows")
    c.expect(!(try! runAgenda(store: store5, json: false, max: 10, now: kstNow, timeZone: kst)).contains("showing"), "no trailer when total <= max")
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
    c.expect(text.contains("(showing 2 of 5 — narrow filters if too many)"), "search trailer reflects total vs shown")
    let rows = text.split(separator: "\n").filter { !$0.hasPrefix("(showing ") }.map(String.init)
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
    let s = FakeCalendarStore(calendars: [work], defaultCalendar: work)
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
          availability: String? = nil, allOccurrences: Bool = false, json: Bool = false, dryRun: Bool = false,
          confirm: Confirmer = AutoYes()) throws -> WriteResult {
    try runEdit(store: s, id: id, title: title, start: start, end: end, duration: duration, tz: tz,
                location: location, notes: notes, url: url, availability: availability,
                allOccurrences: allOccurrences, json: json, dryRun: dryRun, confirm: confirm, now: kstNow, timeZone: kst)
}

do {
    let s = editStore()
    c.expect(try! edit(s, title: "Renamed").performed, "edit applies the change")
    c.eq(s.event(id: "E1")?.title, "Renamed", "edit changes the title")
    c.eq(s.event(id: "E1")?.location, "Old", "edit leaves untouched fields")
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

// Live EventKit round-trip — local only, needs a Calendar grant. CI omits the
// flag and runs the pure suite above. See Integration.swift.
if CommandLine.arguments.contains("--integration") {
    await runIntegrationChecks(c)
}

c.summary()
