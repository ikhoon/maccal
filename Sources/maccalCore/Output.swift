// Output.swift — text (TSV) and NDJSON formatters.
//
// Mirrors macmail's output.ts: human output is TSV for the eyes, `--json` is
// NDJSON (one object per line) for jq / LLM pipelines. Human timestamps render
// in the reader's local zone (with offset); JSON dates are UTC ISO-8601 (Z).

import Foundation

public enum Output {
    /// Shared encoder: UTC ISO-8601 dates, deterministic key order (so tests
    /// and downstream diffs are stable), unescaped slashes for readable URLs.
    public static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// NDJSON: one compact JSON object per line. Empty input → "" (matches
    /// macmail's formatRecords, so callers can append a `_summary` line).
    public static func ndjson(_ items: [some Encodable]) -> String {
        if items.isEmpty { return "" }
        let lines = items.compactMap { item -> String? in
            guard let data = try? jsonEncoder.encode(item) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Encode a single object to one compact JSON line + newline (e.g. a
    /// `{_summary}` trailer or a single `show` record).
    public static func jsonLine(_ item: some Encodable) -> String {
        guard let data = try? jsonEncoder.encode(item),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s + "\n"
    }

    /// Tab-separated rows. Empty input → "".
    public static func tsv(_ rows: [[String]]) -> String {
        if rows.isEmpty { return "" }
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// Local-time ISO-8601 with offset, e.g. `2026-06-02T11:35:00+09:00`.
    public static func localISO(_ d: Date, timeZone tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let off = tz.secondsFromGMT(for: d)
        let sign = off >= 0 ? "+" : "-"
        let ao = abs(off)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, ao / 3600, (ao % 3600) / 60
        )
    }

    /// Bare local calendar date `YYYY-MM-DD` (for all-day events).
    public static func localDate(_ d: Date, timeZone tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The `when` cell for an event row: a bare local date for all-day events,
    /// local ISO-8601 with offset otherwise.
    public static func when(_ event: EventInfo, timeZone tz: TimeZone = .current) -> String {
        event.allDay ? localDate(event.start, timeZone: tz) : localISO(event.start, timeZone: tz)
    }

    /// Best-effort HTML → plain text for event notes (Google/Exchange store rich
    /// text there). No WebKit dependency: links become "text (url)", `<br>`/block
    /// tags become newlines, list items get a "- " bullet, other tags are
    /// stripped, and common entities are decoded. Returns the input unchanged
    /// when it has no markup.
    public static func htmlToPlain(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return s }
        var t = linkify(s)
        func sub(_ pattern: String, _ replacement: String) {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        sub("<li[^>]*>", "\n- ")                       // list item → bullet
        sub("<br\\s*/?>", "\n")                          // line break
        sub("</(p|div|ul|ol|li|tr|h[1-6])>", "\n")        // block close → newline
        sub("<[^>]+>", "")                                // strip remaining tags
        t = decodeEntities(t)
        sub("[ \\t]+\n", "\n")                            // trailing spaces per line
        sub("\n{3,}", "\n\n")                             // collapse blank runs
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<a href="URL">TEXT</a>` → `TEXT (URL)`, or just `URL` when TEXT is empty
    /// or already the URL. Remaining tags in TEXT are stripped by the caller.
    private static func linkify(_ s: String) -> String {
        let pattern = "<a\\b[^>]*?href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range(at: 1))
            let text = ns.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            out += (text.isEmpty || text == url) ? url : "\(text) (\(url))"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        // &amp; last, so "&amp;lt;" doesn't double-decode.
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t
    }

    /// Replace any control character (tab, newline, CR, other C0/C1) and the
    /// Unicode line/paragraph separators with a single space, so a free-text
    /// value stays in one TSV cell and can't split or widen a row — even for a
    /// reader that splits on Unicode newlines.
    public static func sanitize(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" {
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// ANSI styles for human (TTY) output. Applied only when `enabled` — the CLI
    /// turns color on for a TTY and off for pipes, `--json`, `--no-color`, or a
    /// set `NO_COLOR` — so piped and JSON output stays plain.
    public enum Style: String {
        case reset = "\u{001B}[0m"
        case bold = "\u{001B}[1m"
        case dim = "\u{001B}[2m"
        case red = "\u{001B}[31m"
        case green = "\u{001B}[32m"
        case yellow = "\u{001B}[33m"
        case blue = "\u{001B}[34m"
        case magenta = "\u{001B}[35m"
        case cyan = "\u{001B}[36m"
    }

    /// Wrap `s` in the given ANSI styles when `enabled`; otherwise return it
    /// unchanged. Column widths aren't affected because human output is tab-
    /// separated (the terminal aligns on tabs, ignoring the escape codes).
    public static func paint(_ s: String, _ styles: Style..., enabled: Bool) -> String {
        guard enabled, !styles.isEmpty else { return s }
        return styles.map(\.rawValue).joined() + s + Style.reset.rawValue
    }

    /// A truecolor swatch dot + the hex, for `calendars` color output. Falls back
    /// to the bare hex when color is off or the hex can't be parsed.
    public static func colorSwatch(_ hex: String, enabled: Bool) -> String {
        guard enabled else { return hex }
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return hex }
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        return "\u{001B}[38;2;\(r);\(g);\(b)m●\u{001B}[0m \(hex)"
    }

    /// Strip ANSI escape codes — used before persisting a possibly-colorized
    /// summary so files and parsers (e.g. the menu-bar app) see plain text.
    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// A recurring occurrence's stable handle, `<seriesId>@<epoch>` — agenda/search
    /// print this for recurring rows so `edit`/`rm` can target one occurrence.
    public static func occurrenceHandle(id: String, start: Date) -> String {
        "\(id)@\(Int(start.timeIntervalSinceReferenceDate.rounded()))"
    }

    /// Parse `<id>@<epoch>` back to (id, start), or nil when there's no numeric
    /// @epoch suffix (a plain id — including emails like `x@host` — stays plain).
    public static func parseOccurrenceHandle(_ s: String) -> (id: String, start: Date)? {
        guard let at = s.lastIndex(of: "@") else { return nil }
        let id = String(s[..<at])
        // Match occurrenceHandle exactly: a non-empty id and an integer epoch
        // (rejects 1.0 / 1e3 / nan / inf and an empty id).
        guard !id.isEmpty, let epoch = Int(s[s.index(after: at)...]) else { return nil }
        return (id, Date(timeIntervalSinceReferenceDate: Double(epoch)))
    }
}
