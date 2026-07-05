# maccal — Roadmap & Tasks

A fast, scriptable macOS **Calendar** CLI — the Calendar analog of `macmail`. EventKit-backed: no OAuth,
no API, no Full Disk Access — the only permission needed is the Calendars (TCC) grant.

Progress is tracked with the checkboxes below. Legend: ✅ shipped · 🔜 next up · ⬜ planned.
A milestone ships when every box under it is checked and `swift run maccalCheck` stays green.

---

## M1 — Calendar listing & foundation ✅

The testable core, permission gate, output layer, test harness, install path, and the first command.

- [x] SwiftPM package (Swift 6, macOS 14+): `maccalCore` (logic) · `maccal` (CLI wiring) · `maccalCheck` (tests)
- [x] `CalendarStore` protocol seam + `EKCalendarStore` (EK→DTO mapping) + `FakeCalendarStore` for tests
- [x] `calendars` command — `--json` (NDJSON), `--writable`, `--source` filter, stable (source, title) sort
- [x] `CalendarAccess` permission gate — full/write-only/denied, TTY dialog + deep link
- [x] `Output` — TSV (human) + NDJSON (UTC ISO-8601), with `localISO`/`localDate` helpers staged for events
- [x] `maccalCheck` harness — 21 checks, all passing
- [x] `install.sh` — build → codesign (stable id `kr.ikhoon.maccal`, grant survives rebuilds) → symlink into `~/.local`
- [x] `git init`
- [x] Initial commit (M1 import)

---

## M2 — Event read (`agenda` / `show` / `search`) ✅

Read events out of the local store. The date formatters from M1 are already in place for this.

- [x] `EventInfo` (+ `AttendeeInfo`) Codable DTO — full field contract; `start`/`end` as `Date` → UTC-Z in JSON
- [x] Extend `CalendarStore` with `events(in:calendars:)`; map `EKEvent` → `EventInfo` (chunk/dedup/sort) in `EKCalendarStore`
- [x] Event fixtures in `FakeCalendarStore` (+ shared pure helpers: overlaps / matchesCalendar / sortedByStart / deduped)
- [x] Date/range parser (`DateWindow`) — `today` / `tomorrow` / `yesterday` / `YYYY-MM-DD` / `±Nd` / `±Nw` / `--from`/`--to`, DST-correct
- [x] `agenda` command — events in a window (default [today, +7d)); `--calendar` (repeatable), `--from`/`--to`, `--max`, `--json`
- [x] `show <id>` command — full single-event detail (labeled text block or `--json`; missing id → exit 1)
- [x] `search <query>` command — `--in title|location|notes|all`, `--count-only`, `_summary` trailer, `--from`/`--to`/`--max`
- [x] Checks: `events()` mapping, agenda formatting, range parsing, search filtering (113 checks total)

---

## M3 — Event write (`add` / `edit` / `rm`) ✅

Create and modify events. `CalendarAccess` already supports `needsWrite` / write-only grants — wire it up.

- [x] `DateTime` parser — timed `--start`/`--end` (ISO-T, `YYYY-MM-DD HH:MM`, `today HH:MM`, `+Nd HH:MM`) + duration grammar (`30m`/`1h30m`/`1w2d`), DST-correct
- [x] Extend `CalendarStore` with create / update / delete (+ `EventDraft`/`EventChanges` DTOs, `WriteSpan`, `WriteError`/`WriteValidationError`, mutable `FakeCalendarStore`); commands gate with `needsWrite: true`
- [x] `add` command — positional title, `--start`, `--end`/`--duration`, `--all-day`, `--calendar`, `--tz`, `--location`/`--notes`/`--url`, `--availability`, `--json`, `--dry-run`, `--yes`
- [x] `edit <id>` command — patch fields (start-move keeps duration, `''` clears), `--all-occurrences`, `--json`, `--dry-run` (before→after diff), `--yes`. (all-day ↔ timed toggle deferred)
- [x] `rm <id>` command — delete with TTY confirmation + `--yes`, `--all-occurrences`, `--json`, `--dry-run`
- [ ] (stretch, deferred) `respond <id> --accept|--decline|--tentative` — reply to invitations
- [x] Write-path safety — `Confirmer` seam (default No), TTY prompt on stderr, non-TTY refuses without `--yes`, `--dry-run`, `--json` for pipelines
- [x] Checks: create/update/delete against `FakeCalendarStore` state (230 checks total)

---

## M4 — Polish & docs ✅ (declined-events filter still open)

- [x] **Independent Calendar permission** — `.app` bundle + disclaimed re-exec so the grant is keyed on `maccal.app`, not the host terminal; `maccal auth` bootstraps it and the gate guidance points there
- [x] `show` notes rendered as plain text (HTML → text), and the event id moved to the last text column for readability
- [x] Shell completions — generated from the binary by `install.sh` (zsh + bash)
- [x] `README.md` — install, the independent-permission note, command reference, dates/durations, JSON scripting, troubleshooting
- [x] Configuration — `~/.config/maccal/config.json` (shipped beyond the plan: `defaultCalendar`, `hiddenCalendars`, `color`, `dateFormat` incl. custom patterns, `agendaMax`/`searchMax`; precedence flag > env > file > built-in)
- [x] Filtering — `--hide-cancelled` on `agenda`/`search` (shipped), plus config `hiddenCalendars`
- [ ] Filtering — hide *declined* events, once a self-participant flag is mapped onto `AttendeeInfo`
- [x] Versioning — SemVer git tags; the version comes from `git describe`, stamped into the app bundle's Info.plist by `release.sh`/`package.sh` and read at runtime via `AppVersion` (nothing hand-bumped).
- [x] CI — GitHub Actions (`macos-latest`) builds and runs the pure suite (`swift run maccalCheck`) on push/PR. The live EventKit round-trip (`swift run maccalCheck --integration`) is **local-only** (needs a Calendar grant), so CI omits it. (Linux can't build at all: EventKit/AppKit.)

---

## M5 — Calendar sync (`sync`) ✅

One-way mirror of one or more source calendars into a target calendar over a window.

- [x] `sync --from… --to` — `--from` repeats (union of sources); each selector is `"Account/*"` (whole account), `"Account/Calendar"`, or a bare title/identifier (disambiguates names shared across accounts). Idempotent mirror over a date window (default today … +30d); each copy carries a hidden url marker (`maccal-sync://<epoch>/<srcId>`) keyed on the source occurrence (id + start)
- [x] Re-run diff — create new, update changed, mirror-delete gone + duplicate copies (`--no-delete` to keep); only marker-bearing copies are ever touched, so the target's own events are safe
- [x] Detail levels — title+time+location (default; title always included), `--notes` (body), `--no-location` (omit the location); `--since`/`--until`, `--json`, `--dry-run`, `--yes`. (An opaque "Busy" mode — dropping the real title — was removed; the `SyncDetail.title` bit exists but is not exposed on the CLI. Revisit if needed.)
- [x] `WriteValidationError.sameSourceTarget`; source → `calendarNotFound`, ambiguous → `ambiguousCalendar`, read-only target → `notWritable`
- [x] Checks: marker round-trip, account selector, multi-source union, idempotent / update / tz-change / mirror-delete / duplicate-converge / --no-delete / no-location / notes / errors / dry-run / abort against `FakeCalendarStore`

---

## Conventions

- All logic lives in `maccalCore` behind `CalendarStore` so commands are testable with no TCC/EventKit/network.
- Read/list and write commands support `--json` (NDJSON for lists, a single object for one-event commands); human output is an aligned table on a TTY and raw TSV when piped. `export` emits `.ics`; `auth`/`completions` are plain.
- Add a `maccalCheck` case with each new behavior; keep the suite green.

## Shipped since M5 (v0.6.0 – v0.8.x)

- `export` / `import` (iCalendar, incl. TZID), `free` (open slots), natural-language dates, shell `completions`.
- The **maccalbar menu-bar app** — scheduled background sync, Settings window, About, blue tray tint while syncing,
  bundled signed CLI, Homebrew cask.
- The **output overhaul + config file** (#21): aligned CJK-safe tables, readable date ranges + all-day marker,
  calendar-color dots, short git-style ids, the Ink & Token theme, `handle`/`meetingUrl` JSON fields.
- **Online-meeting marker** (#22): 💻 in agenda/search, `Online:` in show, `meetingUrl` in JSON.

## Review notes (deliberate choices from the M2 review)

- **Window flags are `--from`/`--to`** (macmail uses `--since`/`--until`). Chosen for clarity; `--since`/`--until`
  are accepted as aliases everywhere (and are the native flags on `sync`). The upper bound is exclusive, matching macmail's `--until`.
- **Text mode is the human view; `--json` is the machine contract.** When `--max` caps the rows, `agenda`/`search`
  print a `showing M of N …` truncation notice on **stderr** — stdout carries only the data rows. `search --json`
  always emits a final `{"_summary":{…}}` line (even on zero matches). Pipelines should use `--json` (and
  `search --count-only`); stdout never carries a human trailer.
- **`show <id>` of a recurring event resolves the series anchor**, not the specific occurrence seen in agenda/search —
  an `eventIdentifier` carries no occurrence date, so the bare `id` stays the series key (flagged `recurring: true`).
  The specific occurrence *is* now targetable via the `id@epoch` **handle**: shown in the agenda/search last column
  and emitted as the `handle` field in `--json` (show/edit/rm accept it).
- **The permission gate and the thin `main.swift` command wiring are untested by design** — they're bound to live TCC
  and `exit()`; the tested logic lives in the pure `run*` functions. See `Permission.swift`.

### From the M3 (write) review

- **Per-occurrence edit/rm via an occurrence handle.** Recurring rows carry an `id@epoch` handle (a TTY shows a
  short git-style code that resolves to it; the raw handle appears via `--long`, pipes, and `--json` `.handle`);
  `rm <handle>` cancels one occurrence (EXDATE) and `edit <handle>` detach-edits it (non-schedule fields:
  title/location/notes/url/availability). Rescheduling one occurrence, moving its calendar, or changing the
  whole series still uses `--all-occurrences`.
- **Exit codes for writes:** `0` = wrote / dry-ran; `1` = nothing written (validation error, not-found, read-only,
  store failure, **declined prompt**, or non-TTY refusal); `2` = the permission gate. So `maccal rm X && next` won't run
  `next` on a decline.
- **`--json` is one shape across `add`/`edit`/`rm`** — the affected event as a single object (same as `show`), preserving
  `allDay`/`end`/`timeZone`. (`rm` no longer emits a bespoke `{deleted:…}` record — except per-occurrence `rm`, which
  returns a small `{cancelled, occurrence, title}` object.) `edit`'s *text* dry-run shows a
  before→after diff while success echoes the full event — intentional (a new event has no before-state).
- **`add --calendar` takes exactly one calendar** (a new event lives in one), unlike the repeatable `--calendar` union on
  `agenda`/`search`. `edit --calendar` moves an event to another writable calendar.
- **A date-only `--start` (no `--end`/`--duration`) creates an all-day event**; all-day events need whole-day,
  date-only bounds (a clock time or sub-day `--duration` is rejected). The preview/`show` block surfaces `All-day: yes`.
- **all-day ↔ timed toggle on `edit` is deferred** — `edit` preserves an event's all-day-ness and snaps bounds to
  local midnight (DST-safe).
