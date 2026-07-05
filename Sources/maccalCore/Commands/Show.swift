// Commands/Show.swift — `maccal show <id>`.
//
// Prints one event's full detail — the calendar twin of macmail's `read`. Pure
// logic over a CalendarStore (testable via FakeCalendarStore); ShowCommand in
// main.swift parses the id, gates Calendar access, maps a miss to exit 1, and
// prints the output.

import Foundation

/// - Returns: the rendered output and whether the event was found. The command
///   layer turns `found == false` into a stderr message + exit 1.
public func runShow(
    store: CalendarStore,
    id: String,
    json: Bool,
    color: Bool = false,
    dateStyle: Output.DateStyle = .iso,
    now: Date = Date(),
    timeZone: TimeZone = .current
) -> (output: String, found: Bool) {
    guard let event = store.event(id: id) else { return ("", false) }
    return (json ? Output.eventLine(event) : eventDetailText(event, timeZone: timeZone, color: color, dateStyle: dateStyle, now: now), true)
}

/// A vertically labeled block: core fields, then attendees, then the full notes
/// body after a blank line. Empty fields are omitted so the block stays tight.
/// Shared by `show` and the write commands' previews/echoes. Every single-line
/// value is sanitized so a stray newline in a field can't inject a fake label
/// line; the notes body (below the blank line) keeps its real line breaks.
public func eventDetailText(_ e: EventInfo, timeZone: TimeZone, color: Bool = false,
                            dateStyle: Output.DateStyle = .iso, now: Date = Date()) -> String {
    var lines: [String] = []
    func row(_ label: String, _ value: String) {
        guard !value.isEmpty else { return }
        let paddedLabel = label.padding(toLength: 14, withPad: " ", startingAt: 0)
        // Bold label / default-fg value (Ink & Token): structure from weight,
        // never a gray tier — labels and values both read at full contrast.
        lines.append(Output.paint(paddedLabel, .bold, enabled: color) + Output.sanitize(value))
    }

    row("Id:", e.handle)                       // the token to copy into edit/rm/export
    row("Title:", e.title)
    row("When:", whenDetail(e, style: dateStyle, now: now, timeZone: timeZone))
    row("All-day:", e.allDay ? "yes" : "")
    row("Calendar:", e.calendar)
    row("Location:", e.location)
    row("URL:", e.url)
    row("Online:", e.meetingURL ?? "")   // the video-conference link, wherever it hid
    row("Organizer:", e.organizer)
    row("Status:", e.status)
    row("Availability:", e.availability)
    row("Recurring:", e.recurring ? recurrenceSummary(e.recurrenceRule, timeZone: timeZone) : "")

    if !e.attendees.isEmpty {
        lines.append("Attendees:")
        for a in e.attendees {
            let who: String
            if a.name.isEmpty { who = a.email }
            else if a.email.isEmpty { who = a.name }
            else { who = "\(a.name) <\(a.email)>" }
            lines.append("  \(Output.sanitize(who)) — \(a.role)/\(a.status)")
        }
    }

    var out = lines.joined(separator: "\n") + "\n"
    // Notes are often HTML (Google/Exchange); render them as plain text.
    let notes = Output.htmlToPlain(e.notes)
    if !notes.isEmpty { out += "\n\(notes)\n" }
    return out
}

/// The `When:` value. Timed → `start — end`. All-day single day → the date;
/// all-day spanning multiple days → `firstDay — lastDay` (the exclusive end
/// midnight is rolled back to the inclusive last day so humans see the real span).
func whenDetail(_ e: EventInfo, style: Output.DateStyle, now: Date, timeZone: TimeZone) -> String {
    if !e.allDay {
        return "\(Output.formatInstant(e.start, style: style, now: now, timeZone: timeZone)) — \(Output.formatInstant(e.end, style: style, now: now, timeZone: timeZone))"
    }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
    let startDay = Output.formatDay(e.start, style: style, now: now, timeZone: timeZone)
    guard let lastMidnight = cal.date(byAdding: .day, value: -1, to: e.end), lastMidnight > e.start else {
        return startDay                                      // single all-day
    }
    return "\(startDay) — \(Output.formatDay(lastMidnight, style: style, now: now, timeZone: timeZone))"
}

/// A compact human summary of a recurrence rule, e.g. "weekly on Mon, Wed until
/// 2026-12-31" or "every 2 weeks ×10". Falls back to "yes" when the rule is
/// absent (recurring event whose rule we couldn't map).
func recurrenceSummary(_ rule: RecurrenceRule?, timeZone: TimeZone) -> String {
    guard let r = rule else { return "yes" }
    var s = r.interval > 1 ? "every \(r.interval) \(unitPlural(r.frequency))" : r.frequency.rawValue
    if r.frequency == .weekly, !r.daysOfWeek.isEmpty {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = r.daysOfWeek.filter { $0 >= 1 && $0 <= 7 }.map { names[$0] }
        if !days.isEmpty { s += " on \(days.joined(separator: ", "))" }
    }
    if let count = r.count { s += " ×\(count)" }
    else if let until = r.until { s += " until \(Output.localDate(until, timeZone: timeZone))" }
    return s
}

private func unitPlural(_ f: RecurrenceRule.Frequency) -> String {
    switch f {
    case .daily: return "days"
    case .weekly: return "weeks"
    case .monthly: return "months"
    case .yearly: return "years"
    }
}
