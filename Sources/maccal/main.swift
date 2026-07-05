// main.swift — maccal CLI entry point (thin ArgumentParser wiring).
//
// Each subcommand parses its flags, builds the real EKCalendarStore behind the
// Calendar-access gate, and delegates to a pure run* function in maccalCore.
//
// NOTE: this file is named main.swift, so it uses top-level `Maccal.main()`
// rather than the @main attribute (which is disallowed in main.swift).

import ArgumentParser
import Darwin
import EventKit
import Foundation
import maccalCore

// MARK: - TCC responsibility disclaim
//
// A CLI run from a terminal inherits the TERMINAL's Calendar (TCC) grant — its
// "responsible process" is the terminal, so you'd have to grant the whole
// terminal calendar access. To get maccal its OWN grant instead, re-exec
// ourselves once with the responsibility disclaimed: the re-exec'd process is
// attributed to maccal's own code signature (the maccal.app bundle identifier),
// so TCC keys the grant on maccal — not the terminal. stdio/args/exit are
// preserved (POSIX_SPAWN_SETEXEC replaces this process in place), so it's a
// transparent self-bootstrap. If the (private) disclaim symbol is unavailable
// we silently fall back to inheriting the terminal's grant.
private func reexecWithDisclaim() {
    // Calendar-free commands (completion script, help, version) don't need
    // maccal's disclaimed identity — skip the extra exec so a shell rc with
    // `source <(maccal completions --shell zsh)` stays cheap.
    if let first = CommandLine.arguments.dropFirst().first,
       ["completions", "help", "--help", "-h", "--version"].contains(first) {
        return
    }
    guard ProcessInfo.processInfo.environment["MACCAL_DISCLAIMED"] == nil else { return }
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

    // The real on-disk path (symlink resolved → inside maccal.app), so the
    // re-exec carries the bundle identity.
    var size = UInt32(4096)
    var pathBuf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&pathBuf, &size) == 0 else { return }

    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    defer { posix_spawnattr_destroy(&attr) }
    guard setDisclaim(&attr, 1) == 0 else { return }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) // replace, don't fork

    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    var env = ProcessInfo.processInfo.environment
    env["MACCAL_DISCLAIMED"] = "1"
    var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)

    // On success SETEXEC replaces this image (never returns). On failure we just
    // continue (inherit the terminal's grant).
    _ = posix_spawn(nil, pathBuf, nil, &attr, &argv, &envp)
}

struct Maccal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maccal",
        abstract: "macOS Calendar CLI — EventKit-backed. No OAuth, no API, no Full Disk Access.",
        discussion: """
        Examples:
          See your calendars (a title works as a --calendar selector):
            $ maccal calendars

          What's coming up (default: next 7 days):
            $ maccal agenda
            $ maccal agenda --from today --to +1d --calendar Work

          Find events by text, then open one:
            $ maccal search standup
            $ maccal show <id>

          Create / change / delete — preview with --dry-run, commit with --yes:
            $ maccal add "Lunch" --start "tomorrow 12:00" --duration 1h --calendar Work
            $ maccal edit <id> --location "Room 4F"
            $ maccal rm <id>

          First-time setup (grant maccal its own Calendar access):
            $ maccal auth

        The last column of agenda/search is a short git-style id — pass it to show,
        edit, or rm (it's resolved back to the event). Use --long or --json for the
        full id. Run 'maccal <command> --help' for per-command flags.
        """,
        version: AppVersion.current,
        subcommands: [
            CalendarsCommand.self, AgendaCommand.self, ShowCommand.self, SearchCommand.self,
            AddCommand.self, EditCommand.self, RmCommand.self, SyncCommand.self,
            ExportCommand.self, ImportCommand.self, FreeCommand.self, AuthCommand.self,
            CompletionsCommand.self,
        ]
    )
}

// MARK: - Write-command support

/// Prompts on stderr and reads a yes/no from stdin (used only when stdin is a TTY).
struct TTYConfirmer: Confirmer {
    func confirm(_ message: String) -> Bool {
        FileHandle.standardError.write(Data((message + " [y/N] ").utf8))
        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return line == "y" || line == "yes"
    }
}

/// Pick a confirmer for a write op: --yes (and dry-run) skip the prompt; an
/// interactive stdin gets the TTY prompt; otherwise refuse rather than write
/// unattended.
func writeConfirmer(yes: Bool, dryRun: Bool, op: String) throws -> Confirmer {
    if dryRun || yes { return AutoYes() } // dry-run never reaches the confirm branch
    if isatty(fileno(stdin)) == 1 { return TTYConfirmer() }
    FileHandle.standardError.write(Data("maccal: refusing to \(op) without --yes (no TTY for confirmation)\n".utf8))
    throw ExitCode(1)
}

/// Route a WriteResult: stdout for wrote/dryRun; an aborted write notes "aborted"
/// on stderr and exits 1 (nothing written), so `maccal rm X && next` is safe.
func emit(_ result: WriteResult) throws {
    switch result {
    case .wrote(let s), .dryRun(let s): print(s, terminator: "")
    case .aborted:
        FileHandle.standardError.write(Data("maccal: aborted (nothing written)\n".utf8))
        throw ExitCode(1)
    }
}

/// Load CLI defaults from the config file (see maccalCore/Config.swift). A
/// present-but-malformed file is reported on stderr and we fall back to built-in
/// defaults, so a typo can never wedge every command.
func loadConfig() -> Config {
    do {
        return try ConfigLoader.load()
    } catch {
        FileHandle.standardError.write(Data("maccal: ignoring invalid config at \(ConfigLoader.path()): \(error)\n".utf8))
        return Config()
    }
}

/// Whether to colorize human output. `--json` is never colored (clean data);
/// otherwise the config's color mode decides ("auto" = TTY only, "always",
/// "never"), with `--no-color`/NO_COLOR forcing it off. Precedence: flag > env >
/// config > built-in (auto).
func resolveColor(_ config: Config, noColor: Bool, json: Bool) -> Bool {
    if json { return false }
    let envNoColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
    return config.useColor(isTTY: isatty(fileno(stdout)) == 1, flagNoColor: noColor, envNoColor: envNoColor)
}

/// Whether to render human tables column-aligned: only for an interactive stdout
/// and never for `--json`. Piped/redirected output stays raw `\t` TSV so scripts
/// keep parsing with `cut -f` / `awk -F'\t'`. Independent of color.
func useTable(json: Bool) -> Bool {
    !json && isatty(fileno(stdout)) == 1
}

/// On an interactive TTY, nudge on stderr when a read command produced no rows —
/// a bare empty stdout otherwise reads like a hang. Silent for pipes/`--json` so
/// piped data stays clean and empty-means-no-rows.
func emptyNote(_ out: String, json: Bool, _ message: String) {
    if out.isEmpty, useTable(json: json) { Output.warn(message) }
}

/// Resolve a short git-style id (from agenda/search) to its full event handle,
/// or print a `maccal:` message and exit 1. A full id/handle passes through.
func resolveOrExit(_ id: String, store: CalendarStore) throws -> String {
    do { return try resolveEventToken(id, store: store, now: Date(), timeZone: .current) }
    catch let e as MaccalError {
        FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
        throw ExitCode(1)
    }
}

/// Human date style for text output. `--iso` forces ISO; a pipe/redirect also
/// stays ISO (machine contract for `cut`/`awk`); an interactive TTY uses the
/// config's dateFormat ("readable" by default). `--json` dates are separate
/// (always UTC ISO via the encoder), so this doesn't touch them.
func resolveDateStyle(_ config: Config, iso: Bool) -> Output.DateStyle {
    if iso { return .iso }
    if isatty(fileno(stdout)) != 1 { return .iso }
    return Output.DateStyle(rawValue: (config.dateFormat ?? "readable").lowercased()) ?? .readable
}

struct CalendarsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List calendars (use the title as a --calendar selector).",
        discussion: """
        Examples:
          $ maccal calendars             # title, account, type, rw/ro, color
          $ maccal calendars --writable  # only calendars you can modify
          $ maccal calendars --json      # full records (identifier, sourceType, …)

        Use a calendar title or identifier anywhere --calendar is accepted.
        """
    )

    @Flag(name: .long, help: "NDJSON output (one object per line).")
    var json = false

    @Flag(name: .long, help: "Only calendars you can modify.")
    var writable = false

    @Option(name: .long, help: "Filter by source/account title (case-insensitive substring).")
    var source: String?

    @Flag(name: .long, help: "Include calendars hidden via config.hiddenCalendars.")
    var all = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    func run() throws {
        let config = loadConfig()
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        let out = runCalendars(
            store: EKCalendarStore(store: store),
            json: json,
            writableOnly: writable,
            sourceFilter: source,
            hiddenCalendars: config.hiddenCalendars,
            showAll: all,
            color: resolveColor(config, noColor: noColor, json: json),
            aligned: useTable(json: json)
        )
        print(out, terminator: "")
        emptyNote(out, json: json, "no calendars match")
    }
}

struct AgendaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agenda",
        abstract: "List events in a date window, soonest first.",
        discussion: """
        Examples:
          $ maccal agenda                                    # next 7 days, all calendars
          $ maccal agenda --from today --to +1d              # just today
          $ maccal agenda --calendar Work --calendar Akiflow # union of calendars
          $ maccal agenda --from 2026-06-23 --to +5d --max 10
          $ maccal agenda --json | jq -r .title              # pipe to jq

        Columns: [●] · when · [calendar] · id — the ● is the calendar's color, the
        id is a short git-style code (--long or --json for the full id).
        """
    )

    @Flag(name: .long, help: "NDJSON output (one event per line).")
    var json = false

    @Option(name: .long, parsing: .singleValue,
            help: "Calendar to include, by title or identifier (case-insensitive). Repeat to union; omit for all.")
    var calendar: [String] = []

    @Option(name: [.customLong("from"), .customLong("since")], help: "Window start: YYYY-MM-DD, today/tomorrow/yesterday, or ±Nd/±Nw. Default: today. (alias: --since)")
    var from: String?

    @Option(name: [.customLong("to"), .customLong("until")], help: "Window end (exclusive): same forms as --from. Default: --from + 7 days. (alias: --until)")
    var to: String?

    @Option(name: .long, help: "Maximum rows shown. Default: config.agendaMax or 30.")
    var max: Int?

    @Flag(name: .long, help: "Include events from calendars hidden via config.hiddenCalendars.")
    var all = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    @Flag(name: .customLong("iso"), help: "Force ISO-8601 dates (default: config.dateFormat, 'readable' on a TTY).")
    var iso = false

    @Flag(name: .customLong("long"), help: "Show full event ids instead of the short git-style code.")
    var long = false

    @Flag(name: .customLong("hide-cancelled"), help: "Hide events with a cancelled status.")
    var hideCancelled = false

    func run() throws {
        let config = loadConfig()
        // --max flag > config.agendaMax > built-in 30.
        let effectiveMax = max ?? config.agendaMax ?? 30
        guard effectiveMax > 0 else {
            FileHandle.standardError.write(Data("maccal: --max must be a positive integer\n".utf8))
            throw ExitCode(1)
        }
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        do {
            let out = try runAgenda(
                store: EKCalendarStore(store: store),
                json: json, calendars: calendar, from: from, to: to, max: effectiveMax,
                color: resolveColor(config, noColor: noColor, json: json),
                aligned: useTable(json: json),
                dateStyle: resolveDateStyle(config, iso: iso),
                long: long,
                hideCancelled: hideCancelled,
                hiddenCalendars: config.hiddenCalendars,
                showAll: all,
                now: Date(), timeZone: .current
            )
            print(out, terminator: "")
            emptyNote(out, json: json, "no events in this window")
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print one event's full detail by id.",
        discussion: """
        Examples:
          $ maccal show <id>                        # full detail (notes as plain text)
          $ maccal show <id> --json | jq .attendees
          $ maccal show "$(maccal agenda --json | jq -r .id | head -1)"

        The id comes from the agenda / search output (or .id in --json).
        """
    )

    @Argument(help: "Event id from the first column / .id field of agenda or search output.")
    var id: String

    @Flag(name: .long, help: "Single JSON object (every field).")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    @Flag(name: .customLong("iso"), help: "Force ISO-8601 dates (default: config.dateFormat, 'readable' on a TTY).")
    var iso = false

    func run() throws {
        let config = loadConfig()
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        let ck = EKCalendarStore(store: store)
        let resolvedId = try resolveOrExit(id, store: ck)
        let result = runShow(store: ck, id: resolvedId, json: json,
                             color: resolveColor(config, noColor: noColor, json: json),
                             dateStyle: resolveDateStyle(config, iso: iso), now: Date(), timeZone: .current)
        guard result.found else {
            FileHandle.standardError.write(Data("maccal: event \(id) not found\n".utf8))
            throw ExitCode(1)
        }
        print(result.output, terminator: "")
    }
}

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find events matching text within a date window.",
        discussion: """
        Examples:
          $ maccal search standup                # text match, ±30 days, all fields
          $ maccal search 1:1 --in title --json
          $ maccal search review --from today --to +7d
          $ maccal search incident --count-only  # totals only, no rows

        --json appends a final {"_summary":{…}} line with shown/total/examined.
        """
    )

    @Argument(help: "Text matched case-insensitively against the fields chosen by --in.")
    var query: String

    @Flag(name: .long, help: "NDJSON output; final line is a {\"_summary\":{…}} object.")
    var json = false

    @Option(name: .long, parsing: .singleValue,
            help: "Calendar to include, by title or identifier (case-insensitive). Repeat to union; omit for all.")
    var calendar: [String] = []

    @Option(name: .customLong("in"), help: "Fields to match: title | location | notes | all. Default: all.")
    var scope: String = "all"

    @Option(name: [.customLong("from"), .customLong("since")], help: "Window start: YYYY-MM-DD, today/tomorrow/yesterday, or ±Nd/±Nw. Default: today - 30 days. (alias: --since)")
    var from: String?

    @Option(name: [.customLong("to"), .customLong("until")], help: "Window end (exclusive): same forms as --from. Default: --from + 60 days. (alias: --until)")
    var to: String?

    @Option(name: .long, help: "Maximum rows shown. Default: config.searchMax or 10.")
    var max: Int?

    @Flag(name: .long, help: "Print totals only and pull no rows.")
    var countOnly = false

    @Flag(name: .long, help: "Include events from calendars hidden via config.hiddenCalendars.")
    var all = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    @Flag(name: .customLong("iso"), help: "Force ISO-8601 dates (default: config.dateFormat, 'readable' on a TTY).")
    var iso = false

    @Flag(name: .customLong("long"), help: "Show full event ids instead of the short git-style code.")
    var long = false

    @Flag(name: .customLong("hide-cancelled"), help: "Hide events with a cancelled status.")
    var hideCancelled = false

    func run() throws {
        // Validate args before prompting for Calendar access.
        guard let searchScope = SearchScope(rawValue: scope.lowercased()) else {
            FileHandle.standardError.write(Data("maccal: invalid --in value '\(scope)' (use title|location|notes|all)\n".utf8))
            throw ExitCode(1)
        }
        let config = loadConfig()
        // --max flag > config.searchMax > built-in 10.
        let effectiveMax = max ?? config.searchMax ?? 10
        guard effectiveMax > 0 else {
            FileHandle.standardError.write(Data("maccal: --max must be a positive integer\n".utf8))
            throw ExitCode(1)
        }
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        do {
            let out = try runSearch(
                store: EKCalendarStore(store: store),
                query: query, json: json, calendars: calendar, scope: searchScope,
                from: from, to: to, max: effectiveMax, countOnly: countOnly,
                color: resolveColor(config, noColor: noColor, json: json),
                aligned: useTable(json: json),
                dateStyle: resolveDateStyle(config, iso: iso),
                long: long,
                hideCancelled: hideCancelled,
                hiddenCalendars: config.hiddenCalendars,
                showAll: all,
                now: Date(), timeZone: .current
            )
            print(out, terminator: "")
            emptyNote(out, json: json, "no matches")
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a new event and echo it back (text or --json).",
        discussion: """
        Examples:
          $ maccal add "Lunch" --start "tomorrow 12:00" --duration 1h --calendar Work --dry-run
          $ maccal add "Sprint planning" --start "tomorrow 10:00" --end "tomorrow 11:30" --location "Room 4"
          $ maccal add "PTO" --start 2026-07-01 --end 2026-07-04 --all-day --calendar Travel
          $ maccal add "Standup" --start "tomorrow 09:30" --duration 15m --tz Asia/Tokyo --yes

        Give exactly one of --end / --duration. A date-only --start with neither
        makes an all-day event. Preview with --dry-run; commit with --yes.
        """
    )

    @Argument(help: "Event title.")
    var title: String

    @Option(name: .long, help: "Start: date-only (all-day) or timed (YYYY-MM-DDTHH:MM, 'today HH:MM', '+1d HH:MM').")
    var start: String

    @Option(name: .long, help: "Exclusive end, same forms as --start. Mutually exclusive with --duration.")
    var end: String?

    @Option(name: .long, help: "Length from start, e.g. 30m, 1h30m, 2d. Mutually exclusive with --end.")
    var duration: String?

    @Flag(name: .long, help: "All-day event; both bounds must be date-only.")
    var allDay = false

    @Option(name: .long, help: "Target calendar by title or identifier. Omit for the default new-event calendar.")
    var calendar: String?

    @Option(name: .long, help: "IANA time zone id for the wall-clock. Default: local. Ignored for --all-day.")
    var tz: String?

    @Option(name: .long, help: "Location.")
    var location: String?

    @Option(name: .long, help: "Notes/body.")
    var notes: String?

    @Option(name: .long, help: "Associated URL.")
    var url: String?

    @Option(name: .long, help: "busy|free|tentative|unavailable (default busy).")
    var availability: String?

    @Flag(name: .long, help: "Echo the created event as a single JSON object.")
    var json = false

    @Flag(name: .long, help: "Validate and show what would be created; write nothing.")
    var dryRun = false

    @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt (required on a non-TTY).")
    var yes = false

    func run() throws {
        let config = loadConfig()
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "add")
        let store = EKEventStore()
        if !dryRun { CalendarAccess.require(store: store, needsWrite: true) }
        do {
            let result = try runAdd(
                store: EKCalendarStore(store: store),
                title: title, start: start, end: end, duration: duration, allDay: allDay,
                calendar: calendar ?? config.defaultCalendar, tz: tz, location: location, notes: notes, url: url,
                availability: availability, json: json, dryRun: dryRun, confirm: confirmer,
                now: Date(), timeZone: .current
            )
            try emit(result)
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Update fields of an existing event by id; echo the result.",
        discussion: """
        Examples:
          $ maccal edit <id> --location "Room A" --dry-run  # before→after diff
          $ maccal edit <id> --start "tomorrow 16:00"       # end shifts to keep duration
          $ maccal edit <id> --notes "" --yes               # empty string clears a field
          $ maccal edit <id> --title "Renamed" --json

        Recurring events need --all-occurrences. Preview with --dry-run.
        """
    )

    @Argument(help: "Event id from the .id field of agenda/search/show output.")
    var id: String

    @Option(name: .long, help: "New title (cannot be blanked).")
    var title: String?

    @Option(name: .long, help: "New start (same forms as add). Given alone, end shifts to keep the duration. All-day events stay all-day (timed↔all-day toggle not yet supported).")
    var start: String?

    @Option(name: .long, help: "New exclusive end. Mutually exclusive with --duration.")
    var end: String?

    @Option(name: .long, help: "New length from start. Mutually exclusive with --end.")
    var duration: String?

    @Option(name: .long, help: "New IANA time zone id.")
    var tz: String?

    @Option(name: .long, help: "New location; pass an empty string to clear.")
    var location: String?

    @Option(name: .long, help: "New notes; empty string clears.")
    var notes: String?

    @Option(name: .long, help: "New URL; empty string clears.")
    var url: String?

    @Option(name: .long, help: "busy|free|tentative|unavailable.")
    var availability: String?

    @Option(name: .long, help: "Move the event to this calendar (title or identifier; must be writable).")
    var calendar: String?

    @Flag(name: .long, help: "For a recurring series, apply to this and all future occurrences.")
    var allOccurrences = false

    @Flag(name: .long, help: "Echo the updated event as a single JSON object.")
    var json = false

    @Flag(name: .long, help: "Show the before→after diff; write nothing.")
    var dryRun = false

    @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt (required on a non-TTY).")
    var yes = false

    func run() throws {
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "edit")
        let store = EKEventStore()
        CalendarAccess.require(store: store, needsWrite: !dryRun) // dry-run only reads
        let ck = EKCalendarStore(store: store)
        let resolvedId = try resolveOrExit(id, store: ck)
        do {
            let result = try runEdit(
                store: ck,
                id: resolvedId, title: title, start: start, end: end, duration: duration, tz: tz,
                location: location, notes: notes, url: url, availability: availability,
                calendar: calendar,
                allOccurrences: allOccurrences, json: json, dryRun: dryRun, confirm: confirmer,
                now: Date(), timeZone: .current
            )
            try emit(result)
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct RmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete an event by id (destructive).",
        discussion: """
        Examples:
          $ maccal rm <id>            # confirms before deleting
          $ maccal rm <id> --dry-run  # show what would be deleted
          $ maccal rm <id> --yes      # skip the prompt (required when piped)

        Recurring events need --all-occurrences.
        """
    )

    @Argument(help: "Event id from agenda/search/show output.")
    var id: String

    @Flag(name: .long, help: "For a recurring series, delete this and all future occurrences.")
    var allOccurrences = false

    @Flag(name: .long, help: "Emit a JSON object on success.")
    var json = false

    @Flag(name: .long, help: "Show the event that would be deleted; delete nothing.")
    var dryRun = false

    @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt (required on a non-TTY).")
    var yes = false

    func run() throws {
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "rm")
        let store = EKEventStore()
        CalendarAccess.require(store: store, needsWrite: !dryRun) // dry-run only reads
        let ck = EKCalendarStore(store: store)
        let resolvedId = try resolveOrExit(id, store: ck)
        do {
            let result = try runRm(
                store: ck,
                id: resolvedId, allOccurrences: allOccurrences, json: json, dryRun: dryRun,
                confirm: confirmer, timeZone: .current
            )
            try emit(result)
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "One-way mirror of events from one or more calendars into another.",
        discussion: """
        Copies events from one or more --from calendars into --to over a date
        window. A selector is "Account/Calendar" or a bare title/identifier, so
        names that repeat across accounts can be disambiguated. Idempotent: copies
        are marked, so re-running adds new / updates changed / removes gone ones
        (unless --no-delete). Only maccal's own copies are touched.

        Examples:
          $ maccal sync --from "Google/Team" --to "iCloud/Mirror" --dry-run
          $ maccal sync --from Meetings --from Reviews --to Mirror --until +14d --yes
          $ maccal sync --from Meetings --to Mirror --notes          # include the body
          $ maccal sync --from Meetings --to Mirror --no-location     # omit the location

        Run it periodically (e.g. a launchd/cron job with --yes) to stay in sync.
        """
    )

    @Option(name: .long, help: "Source calendar to copy FROM — repeatable. \"Account/*\" (whole account), \"Account/Calendar\", or a title/identifier.")
    var from: [String]

    @Option(name: .long, help: "Target calendar to copy INTO (\"Account/Calendar\" or title/id); must be writable.")
    var to: String

    @Option(name: .long, help: "Window start (default today). Same forms as agenda's --from.")
    var since: String?

    @Option(name: .long, help: "Window end, exclusive (default +30d).")
    var until: String?

    @Flag(name: .long, help: "Also copy the notes/body (default: title, time, location only).")
    var notes = false

    @Flag(name: .long, help: "Omit the location (default: include it).")
    var noLocation = false

    @Flag(name: .long, help: "Keep target copies whose source was deleted (default: mirror-delete them).")
    var noDelete = false

    @Flag(name: .long, help: "Emit the summary as a JSON object.")
    var json = false

    @Flag(name: .long, help: "Show the plan (new/changed/removed) without writing.")
    var dryRun = false

    @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt (required on a non-TTY).")
    var yes = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    func run() throws {
        if from.isEmpty { throw ValidationError("at least one --from is required") }
        let config = loadConfig()
        var detail: SyncDetail = [.title, .location]
        if noLocation { detail.remove(.location) }
        if notes { detail.insert(.notes) }
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "sync")
        let store = EKEventStore()
        CalendarAccess.require(store: store, needsWrite: !dryRun) // dry-run only reads
        do {
            let result = try runSync(
                store: EKCalendarStore(store: store),
                from: from, to: to, since: since, until: until,
                detail: detail, noDelete: noDelete, json: json, dryRun: dryRun,
                color: resolveColor(config, noColor: noColor, json: json),
                confirm: confirmer, now: Date(), timeZone: .current
            )
            try emit(result)
            if case .wrote(let out) = result {
                // Persist a plain (color-stripped) summary so the menu-bar app parses it.
                let plain = Output.stripANSI(out).split(separator: "\n").first.map(String.init) ?? ""
                SyncStatus.record(at: Date(), summary: plain)
            }
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Grant maccal its own Calendar access (run once, interactively).",
        discussion: """
        Examples:
          $ maccal auth   # a "maccal" dialog appears → click Allow

        Grants maccal its own Calendar access, independent of your terminal — run
        once in an interactive Terminal. Reset with your install's bundle id:
          $ tccutil reset Calendar kr.ikhoon.maccal      # standalone CLI
          $ tccutil reset Calendar kr.ikhoon.maccalbar   # bundled in the menu-bar app
        """
    )

    func run() throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            print("maccal already has full Calendar access.")
            return
        }
        // We've already disclaimed responsibility (see reexecWithDisclaim), so
        // this request is attributed to maccal.app — the consent dialog appears
        // as "maccal" and the grant is maccal's own, not the terminal's. Needs an
        // interactive GUI session to show the dialog.
        let store = EKEventStore()
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        store.requestFullAccessToEvents { ok, _ in
            granted = ok
            sem.signal()
        }
        sem.wait()
        if granted {
            print("maccal: Calendar access granted — you can now run maccal commands from any terminal.")
        } else {
            FileHandle.standardError.write(Data((
                "maccal: Calendar access was not granted.\n" +
                "Run `maccal auth` in an interactive Terminal so the \"maccal\" dialog can appear, " +
                "or grant it manually:\n  open \(Bundle.main.bundlePath)\n" +
                "then approve, and check System Settings → Privacy & Security → Calendars (maccal).\n"
            ).utf8))
            throw ExitCode(2)
        }
    }
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export an event as iCalendar (.ics) to stdout.",
        discussion: """
        Examples:
          $ maccal export <id> > event.ics
          $ maccal export <id> | pbcopy

        The id comes from agenda/search/show. Timed events export in UTC; all-day
        events as VALUE=DATE.
        """
    )

    @Argument(help: "Event id from agenda/search/show output.")
    var id: String

    func run() throws {
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        let ck = EKCalendarStore(store: store)
        let resolved = try resolveOrExit(id, store: ck)
        // A recurring occurrence handle (id@epoch) exports the series anchor.
        let seriesId = Output.parseOccurrenceHandle(resolved)?.id ?? resolved
        guard let ev = ck.event(id: seriesId) else {
            FileHandle.standardError.write(Data("maccal: event \(id) not found\n".utf8))
            throw ExitCode(1)
        }
        print(ICS.export(ev, now: Date(), timeZone: .current), terminator: "")
    }
}

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Create events from an iCalendar (.ics) file.",
        discussion: """
        Examples:
          $ maccal import invite.ics --calendar Work --dry-run
          $ maccal import invite.ics --calendar Work --yes
          $ cat invite.ics | maccal import - --yes

        Reads VEVENTs (summary/start/end/location/description/url) and creates them
        in --calendar (or the default). Confirms once for the whole batch.
        """
    )

    @Argument(help: "Path to a .ics file, or - for stdin.")
    var file: String

    @Option(name: .long, help: "Calendar to import into (title or identifier); the default new-event calendar otherwise.")
    var calendar: String?

    @Flag(name: .long, help: "Emit the created events (or the dry-run plan) as JSON.")
    var json = false

    @Flag(name: .long, help: "Show what would be imported; create nothing.")
    var dryRun = false

    @Flag(name: [.long, .customShort("y")], help: "Skip the confirmation prompt (required on a non-TTY).")
    var yes = false

    func run() throws {
        let text: String
        if file == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let s = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(Data("maccal: stdin is not valid UTF-8\n".utf8))
                throw ExitCode(1)
            }
            text = s
        } else {
            guard let s = try? String(contentsOfFile: file, encoding: .utf8) else {
                FileHandle.standardError.write(Data("maccal: cannot read \(file)\n".utf8))
                throw ExitCode(1)
            }
            text = s
        }
        let drafts = ICS.parse(text, timeZone: .current)
        let config = loadConfig()
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "import")
        let store = EKEventStore()
        CalendarAccess.require(store: store, needsWrite: !dryRun)
        do {
            let result = try runImport(store: EKCalendarStore(store: store), drafts: drafts,
                                       calendar: calendar ?? config.defaultCalendar, json: json,
                                       dryRun: dryRun, confirm: confirmer, timeZone: .current)
            try emit(result)
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct FreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "free",
        abstract: "Find open slots in your working hours.",
        discussion: """
        Examples:
          $ maccal free --duration 1h                    # next 7 days, 09–18
          $ maccal free --duration 30m --within +3d
          $ maccal free --duration 1h --work-start 10 --work-end 17 --json

        Lists your OWN open slots (busy = events not marked free). It doesn't
        coordinate with anyone else's calendar.
        """
    )

    @Option(name: .long, help: "Minimum slot length: 30m, 1h, 1h30m.")
    var duration: String

    @Option(name: [.customLong("from"), .customLong("since")], help: "Window start (default today).")
    var from: String?

    @Option(name: [.customLong("within"), .customLong("to"), .customLong("until")], help: "Window end (default +7d).")
    var within: String?

    @Option(name: .customLong("work-start"), help: "Work-day start hour, 0–24 (default 9).")
    var workStart: Int = 9

    @Option(name: .customLong("work-end"), help: "Work-day end hour, 0–24 (default 18).")
    var workEnd: Int = 18

    @Option(name: .long, parsing: .singleValue, help: "Calendar to consider (repeatable; default all).")
    var calendar: [String] = []

    @Flag(name: .long, help: "Consider events from calendars hidden via config.hiddenCalendars.")
    var all = false

    @Flag(name: .long, help: "NDJSON output (start/end/minutes).")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color (also off for pipes, --json, or NO_COLOR).")
    var noColor = false

    @Flag(name: .customLong("iso"), help: "Force ISO-8601 dates (default: config.dateFormat, 'readable' on a TTY).")
    var iso = false

    func run() throws {
        guard workStart >= 0, workEnd <= 24, workStart < workEnd else {
            FileHandle.standardError.write(Data("maccal: --work-start/--work-end must be 0–24 with start < end\n".utf8))
            throw ExitCode(1)
        }
        let config = loadConfig()
        let tz = TimeZone.current
        do {
            let window = try DateWindow.window(from: from, to: within, now: Date(), timeZone: tz,
                                               defaultFromDays: 0, defaultSpanDays: 7)
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let comps = try DateTime.parseDuration(duration)
            guard let durEnd = cal.date(byAdding: comps, to: window.start), durEnd > window.start else {
                FileHandle.standardError.write(Data("maccal: --duration must be positive\n".utf8))
                throw ExitCode(1)
            }
            let minDuration = durEnd.timeIntervalSince(window.start)
            let store = EKEventStore()
            CalendarAccess.require(store: store)
            let out = runFree(store: EKCalendarStore(store: store), window: window, minDuration: minDuration,
                              workStartHour: workStart, workEndHour: workEnd, calendars: calendar,
                              hiddenCalendars: config.hiddenCalendars, showAll: all,
                              json: json, color: resolveColor(config, noColor: noColor, json: json),
                              aligned: useTable(json: json), dateStyle: resolveDateStyle(config, iso: iso),
                              now: Date(), timeZone: tz)
            print(out, terminator: "")
            emptyNote(out, json: json, "no free slots in the window")
        } catch let e as MaccalError {
            FileHandle.standardError.write(Data("maccal: \(e.description)\n".utf8))
            throw ExitCode(1)
        }
    }
}

struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Print the shell completion script, or install it with --install.",
        discussion: """
        Examples:
          $ maccal completions --install               # install for your $SHELL
          $ maccal completions --shell zsh --install
          $ source <(maccal completions --shell zsh)   # or load it directly

        --install writes under $XDG_DATA_HOME (default ~/.local/share) and prints
        how to enable it. Bundled so a binary install needs no install.sh.
        """
    )

    @Option(name: .long, help: "zsh | bash | fish (default: inferred from $SHELL).")
    var shell: String?

    @Flag(name: .long, help: "Write the script to the standard location and print how to enable it.")
    var install = false

    func run() throws {
        let name = shell ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        let kind: CompletionShell
        switch name {
        case "zsh": kind = .zsh
        case "bash": kind = .bash
        case "fish": kind = .fish
        default:
            FileHandle.standardError.write(Data("maccal: unsupported shell '\(name)' (use zsh|bash|fish)\n".utf8))
            throw ExitCode(2)
        }
        let script = Maccal.completionScript(for: kind)
        guard install else {
            print(script)
            return
        }
        try installCompletion(script, shell: name)
    }
}

/// Write a completion script to the standard per-user (XDG) location and print
/// how to enable it. Shared by `maccal completions --install` and install.sh.
func installCompletion(_ script: String, shell: String) throws {
    let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.local/share")
    let dir: String
    let file: String
    switch shell {
    case "zsh": dir = "\(dataHome)/zsh/site-functions"; file = "_maccal"
    case "fish": dir = "\(dataHome)/fish/vendor_completions.d"; file = "maccal.fish"
    default: dir = "\(dataHome)/bash-completion/completions"; file = "maccal"
    }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/\(file)"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    print("maccal: \(shell) completion installed → \(path)")
    switch shell {
    case "zsh":
        print("  Enable it by adding to ~/.zshrc before compinit:")
        print("      fpath=(\(dir) $fpath)")
        print("  then open a new shell.")
    case "fish":
        print("  fish loads this automatically in new shells.")
    default:
        print("  bash-completion loads this automatically in new shells.")
    }
}

reexecWithDisclaim()
Maccal.main()
