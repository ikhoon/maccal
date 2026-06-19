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

        The id in the last column of agenda/search output is what you pass to show,
        edit, and rm. Run 'maccal <command> --help' for per-command flags.
        """,
        version: "0.2.0",
        subcommands: [
            CalendarsCommand.self, AgendaCommand.self, ShowCommand.self, SearchCommand.self,
            AddCommand.self, EditCommand.self, RmCommand.self, AuthCommand.self,
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
        FileHandle.standardError.write(Data("aborted\n".utf8))
        throw ExitCode(1)
    }
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

    func run() throws {
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        let out = runCalendars(
            store: EKCalendarStore(store: store),
            json: json,
            writableOnly: writable,
            sourceFilter: source
        )
        print(out, terminator: "")
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

        Columns: when · [calendar] · title · id (id last; use --json for scripting).
        """
    )

    @Flag(name: .long, help: "NDJSON output (one event per line).")
    var json = false

    @Option(name: .long, parsing: .singleValue,
            help: "Calendar to include, by title or identifier (case-insensitive). Repeat to union; omit for all.")
    var calendar: [String] = []

    @Option(name: .long, help: "Window start: YYYY-MM-DD, today/tomorrow/yesterday, or ±Nd/±Nw. Default: today.")
    var from: String?

    @Option(name: .long, help: "Window end (exclusive): same forms as --from. Default: --from + 7 days.")
    var to: String?

    @Option(name: .long, help: "Maximum rows shown. Default: 20.")
    var max: Int = 20

    func run() throws {
        // Validate args before prompting for Calendar access.
        guard max > 0 else {
            FileHandle.standardError.write(Data("maccal: --max must be a positive integer\n".utf8))
            throw ExitCode(1)
        }
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        do {
            let out = try runAgenda(
                store: EKCalendarStore(store: store),
                json: json, calendars: calendar, from: from, to: to, max: max,
                now: Date(), timeZone: .current
            )
            print(out, terminator: "")
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

    func run() throws {
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        let result = runShow(store: EKCalendarStore(store: store), id: id, json: json, timeZone: .current)
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

    @Option(name: .long, help: "Window start: YYYY-MM-DD, today/tomorrow/yesterday, or ±Nd/±Nw. Default: today - 30 days.")
    var from: String?

    @Option(name: .long, help: "Window end (exclusive): same forms as --from. Default: --from + 60 days.")
    var to: String?

    @Option(name: .long, help: "Maximum rows shown. Default: 10.")
    var max: Int = 10

    @Flag(name: .long, help: "Print totals only and pull no rows.")
    var countOnly = false

    func run() throws {
        // Validate args before prompting for Calendar access.
        guard let searchScope = SearchScope(rawValue: scope.lowercased()) else {
            FileHandle.standardError.write(Data("maccal: invalid --in value '\(scope)' (use title|location|notes|all)\n".utf8))
            throw ExitCode(1)
        }
        guard max > 0 else {
            FileHandle.standardError.write(Data("maccal: --max must be a positive integer\n".utf8))
            throw ExitCode(1)
        }
        let store = EKEventStore()
        CalendarAccess.require(store: store)
        do {
            let out = try runSearch(
                store: EKCalendarStore(store: store),
                query: query, json: json, calendars: calendar, scope: searchScope,
                from: from, to: to, max: max, countOnly: countOnly,
                now: Date(), timeZone: .current
            )
            print(out, terminator: "")
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
        let confirmer = try writeConfirmer(yes: yes, dryRun: dryRun, op: "add")
        let store = EKEventStore()
        if !dryRun { CalendarAccess.require(store: store, needsWrite: true) }
        do {
            let result = try runAdd(
                store: EKCalendarStore(store: store),
                title: title, start: start, end: end, duration: duration, allDay: allDay,
                calendar: calendar, tz: tz, location: location, notes: notes, url: url,
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
        do {
            let result = try runEdit(
                store: EKCalendarStore(store: store),
                id: id, title: title, start: start, end: end, duration: duration, tz: tz,
                location: location, notes: notes, url: url, availability: availability,
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
        do {
            let result = try runRm(
                store: EKCalendarStore(store: store),
                id: id, allOccurrences: allOccurrences, json: json, dryRun: dryRun,
                confirm: confirmer, timeZone: .current
            )
            try emit(result)
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
        once in an interactive Terminal. Reset with:
          $ tccutil reset Calendar kr.ikhoon.maccal
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
