// Output.swift — text (TSV) and NDJSON formatters.
//
// Mirrors macmail's output.ts: human output is TSV for the eyes, `--json` is
// NDJSON (one object per line) for jq / LLM pipelines. Human timestamps render
// in the reader's local zone (with offset); JSON dates are UTC ISO-8601 (Z).

import Foundation
import CryptoKit

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

    /// Wraps an EventInfo so its JSON gains a `handle` — the exact token the human
    /// last column shows and that show/edit/rm accept: the series `id`, or
    /// `id@epoch` for a specific recurring occurrence. Keeps text and `--json` in
    /// sync so `agenda --json | jq -r .handle | … edit/rm` targets the same thing.
    private struct EventEnvelope: Encodable {
        let event: EventInfo
        var handle: String { event.handle }
        enum CodingKeys: String, CodingKey { case handle }
        func encode(to encoder: Encoder) throws {
            try event.encode(to: encoder)                       // all EventInfo keys…
            var c = encoder.container(keyedBy: CodingKeys.self) // …plus handle, merged
            try c.encode(handle, forKey: .handle)
        }
    }

    /// NDJSON of events, each with an added `handle` field. Use for agenda/search.
    public static func eventsNDJSON(_ events: [EventInfo]) -> String {
        ndjson(events.map { EventEnvelope(event: $0) })
    }

    /// One event as a JSON line, with an added `handle` field. Use for `show`.
    public static func eventLine(_ event: EventInfo) -> String {
        jsonLine(EventEnvelope(event: event))
    }

    /// Write a one-line notice to stderr, prefixed `maccal:`. Truncation notices
    /// and TTY empty-state hints go here so stdout (the data / --json) stays clean
    /// and pipe-parseable.
    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("maccal: \(message)\n".utf8))
    }

    /// Tab-separated rows. Empty input → "". This is the machine form: one `\t`
    /// between cells so `cut -f` / `awk -F'\t'` work. Piped and `--json`-adjacent
    /// output uses this; a human TTY uses `table(_:aligned:)` instead.
    public static func tsv(_ rows: [[String]]) -> String {
        if rows.isEmpty { return "" }
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// Render rows for output: a space-padded, column-aligned table when `aligned`
    /// (a human TTY), else the raw `\t` TSV (pipes / `--json` context) so scripts
    /// still parse. Column widths use `displayWidth` — ANSI escapes count 0 and
    /// East-Asian wide characters count 2 — so colored, bilingual rows line up.
    /// The last cell is never padded (no trailing spaces). Empty input → "".
    public static func table(_ rows: [[String]], aligned: Bool, gutter: Int = 2) -> String {
        if rows.isEmpty { return "" }
        if !aligned { return tsv(rows) }
        let cols = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: cols)
        for r in rows {
            for (i, c) in r.enumerated() { widths[i] = max(widths[i], displayWidth(c)) }
        }
        let lines = rows.map { r -> String in
            var out = ""
            for (i, c) in r.enumerated() {
                out += c
                if i < r.count - 1 {                       // pad every cell but the last
                    out += String(repeating: " ", count: widths[i] - displayWidth(c) + gutter)
                }
            }
            return out
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Visible column width of `s` as a terminal renders it: ANSI SGR escapes are
    /// invisible (0), East-Asian Wide/Fullwidth scalars take 2 cells, combining /
    /// zero-width scalars take 0, everything else 1. Used by `table` so alignment
    /// survives color codes and CJK text. Approximate for exotic emoji ZWJ
    /// sequences (over-counts), which don't appear in calendar/account names.
    public static func displayWidth(_ s: String) -> Int {
        let plain = stripANSI(s)
        var w = 0
        var prevNarrow = false          // last scalar contributed width 1 (FE0F can upgrade it to 2)
        for u in plain.unicodeScalars {
            if u.value == 0xFE0F {       // emoji variation selector: force emoji (width-2) presentation
                if prevNarrow { w += 1; prevNarrow = false }
                continue
            }
            let cw = scalarWidth(u)
            w += cw
            prevNarrow = (cw == 1)
        }
        return w
    }

    /// wcwidth-style width for one scalar: 0 / 1 / 2. Kept private; callers use
    /// `displayWidth` on whole (possibly colored) strings.
    private static func scalarWidth(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        // Zero-width: C0/C1 controls, combining marks, ZW joiners, variation
        // selectors, BOM/ZWNBSP. (Tabs/newlines are sanitized out upstream.)
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        switch u.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if v == 0x200B || v == 0xFEFF { return 0 }
        // Default emoji-presentation scalars render as width 2 (e.g. ✅ U+2705,
        // which East-Asian-Width would otherwise call narrow). Covers the symbol/
        // dingbat emoji in 0x2000–0x2BFF without widening their text-presentation
        // siblings.
        if u.properties.isEmojiPresentation { return 2 }
        // East-Asian Wide / Fullwidth ranges (Hangul, CJK, kana, fullwidth forms,
        // emoji planes, CJK extensions).
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
            0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
            0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
            0x1F000...0x1FAFF, 0x20000...0x3FFFD,
        ]
        for r in wide where r.contains(v) { return 2 }
        return 1
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
    public static func when(_ event: EventInfo, style: DateStyle = .iso, timeZone tz: TimeZone = .current, now: Date = Date()) -> String {
        event.allDay ? formatDay(event.start, style: style, now: now, timeZone: tz)
                     : formatInstant(event.start, style: style, now: now, timeZone: tz)
    }

    /// Human date styles for TEXT output. Pipes and `--json` always stay ISO/UTC
    /// (machine contract); only an interactive TTY uses a readable style.
    ///   iso      → 2026-07-06T09:30:00+09:00   (local, with offset — the machine form)
    ///   readable → 2026-07-06 09:30            (default: date + HH:MM, no seconds/offset)
    ///   friendly → Mon Jul 6 09:30             (weekday + month name)
    ///   compact  → Jul 6 09:30                 (month name + day; year added when not `now`'s year)
    public enum DateStyle: String, Sendable, CaseIterable { case iso, readable, friendly, compact }

    private static let monthAbbr = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdayAbbr = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// A timed instant in the given style. `now` only affects `compact`'s year.
    public static func formatInstant(_ d: Date, style: DateStyle, now: Date = Date(), timeZone tz: TimeZone = .current) -> String {
        switch style {
        case .iso: return localISO(d, timeZone: tz)
        case .readable: return "\(localDate(d, timeZone: tz)) \(hhmm(d, tz))"
        case .friendly: return "\(weekdayName(d, tz)) \(monthDay(d, tz, now: now)) \(hhmm(d, tz))"
        case .compact: return "\(monthDay(d, tz, now: now)) \(hhmm(d, tz))"
        }
    }

    /// An all-day date (no clock) in the given style.
    public static func formatDay(_ d: Date, style: DateStyle, now: Date = Date(), timeZone tz: TimeZone = .current) -> String {
        switch style {
        case .iso, .readable: return localDate(d, timeZone: tz)          // 2026-07-06
        case .friendly: return "\(weekdayName(d, tz)) \(monthDay(d, tz, now: now))"
        case .compact: return monthDay(d, tz, now: now)
        }
    }

    private static func comps(_ d: Date, _ tz: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
    }
    private static func hhmm(_ d: Date, _ tz: TimeZone) -> String {
        let c = comps(d, tz); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    private static func weekdayName(_ d: Date, _ tz: TimeZone) -> String {
        weekdayAbbr[comps(d, tz).weekday ?? 0]
    }
    /// `Jul 6`, plus ` 2027` when the date's year differs from `now`'s.
    private static func monthDay(_ d: Date, _ tz: TimeZone, now: Date) -> String {
        let c = comps(d, tz)
        let base = "\(monthAbbr[c.month ?? 0]) \(c.day ?? 0)"
        return (c.year ?? 0) == (comps(now, tz).year ?? 0) ? base : "\(base) \(c.year ?? 0)"
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
        sub("<!--[\\s\\S]*?-->", "")                     // HTML/conditional comments (before the <! strip)
        sub("<![^>]*>", "")                              // <!DOCTYPE …> and other declarations
        sub("<li[^>]*>", "\n- ")                       // list item → bullet
        sub("<br\\s*/?>", "\n")                          // line break
        sub("</(p|div|ul|ol|li|tr|h[1-6])>", "\n")        // block close → newline
        // Strip only real element tags: '<' or '</' followed by a letter. A literal
        // '<' in prose ("a < b", "5 < 10") isn't a tag, so its text is kept.
        sub("</?[a-zA-Z][^>]*>", "")
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
    /// The "Ink & Token" theme palette. Hierarchy is built from WEIGHT, not gray:
    /// bold = the one primary element per view; default fg = all other text (so
    /// bilingual names always render at full terminal contrast — no SGR dim, no
    /// gray tier, ever); normal-intensity ANSI hues are rationed to semantics:
    /// cyan = the copyable id token, green/yellow/red/magenta = states. Normal
    /// (not bright-9x) codes so light terminal palettes keep contrast too.
    public enum Style: String {
        case reset = "\u{001B}[0m"
        case bold = "\u{001B}[1m"
        case red = "\u{001B}[31m"
        case green = "\u{001B}[32m"
        case yellow = "\u{001B}[33m"
        case blue = "\u{001B}[34m"
        case magenta = "\u{001B}[35m"
        case cyan = "\u{001B}[36m"
    }

    /// Wrap `s` in the given ANSI styles when `enabled`; otherwise return it
    /// unchanged. Safe inside `table` columns: `displayWidth` strips these escapes
    /// before measuring, so colored cells still align.
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

    /// A bare truecolor dot in the calendar's own color, no hex — the leading
    /// marker in `calendars` human output. An unparseable hex falls back to a
    /// plain dot so the column stays present and aligned. (Callers add this only
    /// when color is on; the hex still ships in `--json`.)
    public static func colorDot(_ hex: String) -> String {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return "●" }
        let (r, g, b) = visible((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        return "\u{001B}[38;2;\(r);\(g);\(b)m●\u{001B}[0m"
    }

    /// Raise a too-dark RGB toward a minimum brightness (preserving hue) so a
    /// dark-colored calendar's dot stays visible on a dark terminal. Black → gray.
    private static func visible(_ r: Int, _ g: Int, _ b: Int, floor: Int = 128) -> (Int, Int, Int) {
        let m = max(r, g, b)
        if m >= floor { return (r, g, b) }
        if m == 0 { return (floor, floor, floor) }
        let s = Double(floor) / Double(m)
        return (Int((Double(r) * s).rounded()), Int((Double(g) * s).rounded()), Int((Double(b) * s).rounded()))
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

    /// A short, stable, git-style code for an event handle: the first 7 hex chars
    /// of its SHA-256. Deterministic across runs, so agenda/search can show it in
    /// place of the long EK id and show/edit/rm/export resolve it back by scanning
    /// a window. The full id/handle still works everywhere; `--long`/`--json` show it.
    public static func shortId(_ handle: String) -> String {
        let hex = SHA256.hash(data: Data(handle.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(7))
    }

    /// True when `token` has the shape of a `shortId` (exactly 7 lowercase hex
    /// chars), so callers can tell a short code from a full EK id/handle.
    public static func isShortId(_ token: String) -> Bool {
        token.count == 7 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
