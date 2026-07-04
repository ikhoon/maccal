// ICS.swift — minimal iCalendar (RFC 5545) export/import for single events.
//
// Covers the common VEVENT fields (SUMMARY / DTSTART / DTEND / LOCATION /
// DESCRIPTION / URL), timed events in UTC and all-day events as VALUE=DATE.
// A full VTIMEZONE / RRULE round-trip is out of scope: imported timed events are
// read at their UTC instant, imported dates as local midnight. Pure (no clock
// reads); the CLI passes `now` for DTSTAMP and the reader's time zone.

import Foundation

public enum ICS {
    // MARK: escaping (RFC 5545 §3.3.11)

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var esc = false
        for ch in s {
            if esc {
                switch ch { case "n", "N": out.append("\n"); default: out.append(ch) }
                esc = false
            } else if ch == "\\" {
                esc = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: date stamps (manual, so no non-Sendable DateFormatter)

    private static func cal(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }

    /// `yyyyMMddTHHmmssZ` (UTC) for a timed instant.
    static func utcStamp(_ d: Date) -> String {
        let c = cal(TimeZone(identifier: "UTC")!).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `yyyyMMdd` in `tz` — an all-day date carries no clock time, so use the
    /// reader's local calendar day.
    static func dateStamp(_ d: Date, _ tz: TimeZone) -> String {
        let c = cal(tz).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func parseUTCStamp(_ s: String) -> Date? {
        let cs = Array(s)
        guard cs.count == 16, cs[8] == "T", cs[15] == "Z",
              let y = Int(String(cs[0..<4])), let mo = Int(String(cs[4..<6])), let da = Int(String(cs[6..<8])),
              let h = Int(String(cs[9..<11])), let mi = Int(String(cs[11..<13])), let se = Int(String(cs[13..<15]))
        else { return nil }
        return cal(TimeZone(identifier: "UTC")!).date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi, second: se))
    }

    /// A floating timed stamp `yyyyMMddTHHmmss` (no Z) — read in `tz`.
    static func parseFloatingStamp(_ s: String, _ tz: TimeZone) -> Date? {
        let cs = Array(s)
        guard cs.count == 15, cs[8] == "T",
              let y = Int(String(cs[0..<4])), let mo = Int(String(cs[4..<6])), let da = Int(String(cs[6..<8])),
              let h = Int(String(cs[9..<11])), let mi = Int(String(cs[11..<13])), let se = Int(String(cs[13..<15]))
        else { return nil }
        return cal(tz).date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi, second: se))
    }

    /// A `yyyyMMdd` date → local midnight in `tz`.
    static func parseDateStamp(_ s: String, _ tz: TimeZone) -> Date? {
        let cs = Array(s)
        guard cs.count == 8, let y = Int(String(cs[0..<4])), let mo = Int(String(cs[4..<6])), let da = Int(String(cs[6..<8]))
        else { return nil }
        return cal(tz).date(from: DateComponents(year: y, month: mo, day: da))
    }

    // MARK: export

    /// One event as a VCALENDAR with a single VEVENT. Lines use CRLF per the spec.
    public static func export(_ e: EventInfo, now: Date, timeZone: TimeZone = .current) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//maccal//maccal//EN", "CALSCALE:GREGORIAN", "BEGIN:VEVENT"]
        lines.append("UID:\(e.id.isEmpty ? "maccal-\(Int(e.start.timeIntervalSinceReferenceDate.rounded()))" : e.id)")
        lines.append("DTSTAMP:\(utcStamp(now))")
        if e.allDay {
            lines.append("DTSTART;VALUE=DATE:\(dateStamp(e.start, timeZone))")
            lines.append("DTEND;VALUE=DATE:\(dateStamp(e.end, timeZone))")
        } else {
            lines.append("DTSTART:\(utcStamp(e.start))")
            lines.append("DTEND:\(utcStamp(e.end))")
        }
        lines.append("SUMMARY:\(escape(e.title))")
        if !e.location.isEmpty { lines.append("LOCATION:\(escape(e.location))") }
        if !e.notes.isEmpty { lines.append("DESCRIPTION:\(escape(e.notes))") }
        if !e.url.isEmpty { lines.append("URL:\(e.url)") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: import

    /// Parse every VEVENT into an EventDraft (calendar/availability left to the
    /// caller's defaults). Unknown properties and other components are ignored.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [EventDraft] {
        // Unfold RFC 5545 line folding: a line beginning with space/tab continues the previous.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line.dropFirst()
            } else {
                unfolded.append(String(line))
            }
        }

        var drafts: [EventDraft] = []
        var fields: [String: (params: String, value: String)]? = nil
        for line in unfolded {
            if line == "BEGIN:VEVENT" { fields = [:]; continue }
            if line == "END:VEVENT" {
                if let f = fields, let d = draft(from: f, timeZone: timeZone) { drafts.append(d) }
                fields = nil
                continue
            }
            guard fields != nil, let colon = line.firstIndex(of: ":") else { continue }
            let namePart = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            if let semi = namePart.firstIndex(of: ";") {
                fields?[String(namePart[..<semi]).uppercased()] = (String(namePart[namePart.index(after: semi)...]), value)
            } else {
                fields?[namePart.uppercased()] = ("", value)
            }
        }
        return drafts
    }

    private static func draft(from f: [String: (params: String, value: String)], timeZone tz: TimeZone) -> EventDraft? {
        guard let dtstart = f["DTSTART"] else { return nil }
        let startIsDate = dtstart.params.uppercased().contains("VALUE=DATE") || (dtstart.value.count == 8 && !dtstart.value.contains("T"))
        let start: Date?
        if startIsDate { start = parseDateStamp(dtstart.value, tz) }
        else if dtstart.value.hasSuffix("Z") { start = parseUTCStamp(dtstart.value) }
        else { start = parseFloatingStamp(dtstart.value, tz) }
        guard let start else { return nil }

        let end: Date
        if let dtend = f["DTEND"] {
            let endIsDate = dtend.params.uppercased().contains("VALUE=DATE") || (dtend.value.count == 8 && !dtend.value.contains("T"))
            let parsed = endIsDate ? parseDateStamp(dtend.value, tz)
                : (dtend.value.hasSuffix("Z") ? parseUTCStamp(dtend.value) : parseFloatingStamp(dtend.value, tz))
            end = parsed ?? (startIsDate ? cal(tz).date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600))
        } else {
            end = startIsDate ? cal(tz).date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600)
        }

        let title = unescape(f["SUMMARY"]?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return EventDraft(
            title: title.isEmpty ? "(untitled)" : title,
            start: start, end: end, allDay: startIsDate,
            location: unescape(f["LOCATION"]?.value ?? ""),
            notes: unescape(f["DESCRIPTION"]?.value ?? ""),
            url: f["URL"]?.value ?? ""
        )
    }
}
