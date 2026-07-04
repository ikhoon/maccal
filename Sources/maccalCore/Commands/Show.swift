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
    timeZone: TimeZone = .current
) -> (output: String, found: Bool) {
    guard let event = store.event(id: id) else { return ("", false) }
    return (json ? Output.jsonLine(event) : eventDetailText(event, timeZone: timeZone, color: color), true)
}

/// A vertically labeled block: core fields, then attendees, then the full notes
/// body after a blank line. Empty fields are omitted so the block stays tight.
/// Shared by `show` and the write commands' previews/echoes.
public func eventDetailText(_ e: EventInfo, timeZone: TimeZone, color: Bool = false) -> String {
    var lines: [String] = []
    func row(_ label: String, _ value: String) {
        guard !value.isEmpty else { return }
        let paddedLabel = label.padding(toLength: 14, withPad: " ", startingAt: 0)
        lines.append(Output.paint(paddedLabel, .dim, enabled: color) + value)
    }

    let when = e.allDay
        ? Output.localDate(e.start, timeZone: timeZone)
        : "\(Output.localISO(e.start, timeZone: timeZone)) — \(Output.localISO(e.end, timeZone: timeZone))"

    row("Title:", e.title)
    row("When:", when)
    row("All-day:", e.allDay ? "yes" : "")
    row("Calendar:", e.calendar)
    row("Location:", e.location)
    row("URL:", e.url)
    row("Organizer:", e.organizer)
    row("Status:", e.status)
    row("Availability:", e.availability)
    row("Recurring:", e.recurring ? "yes" : "")

    if !e.attendees.isEmpty {
        lines.append("Attendees:")
        for a in e.attendees {
            let who: String
            if a.name.isEmpty { who = a.email }
            else if a.email.isEmpty { who = a.name }
            else { who = "\(a.name) <\(a.email)>" }
            lines.append("  \(who) — \(a.role)/\(a.status)")
        }
    }

    var out = lines.joined(separator: "\n") + "\n"
    // Notes are often HTML (Google/Exchange); render them as plain text.
    let notes = Output.htmlToPlain(e.notes)
    if !notes.isEmpty { out += "\n\(notes)\n" }
    return out
}
