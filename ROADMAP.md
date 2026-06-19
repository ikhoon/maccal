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
- [x] `CalendarAccess` permission gate — full/write-only/denied, TTY dialog + deep link, `MACCAL_NO_PERMISSION_PROMPT`
- [x] `Output` — TSV (human) + NDJSON (UTC ISO-8601), with `localISO`/`localDate` helpers staged for events
- [x] `maccalCheck` harness — 21 checks, all passing
- [x] `install.sh` — build → codesign (stable id `kr.ikhoon.maccal`, grant survives rebuilds) → symlink into `~/.local`
- [x] `git init`
- [ ] Initial commit (M1 import)

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

## M4 — Polish & docs 🔜

- [x] **Independent Calendar permission** — `.app` bundle + disclaimed re-exec so the grant is keyed on `maccal.app`, not the host terminal; `maccal auth` bootstraps it and the gate guidance points there
- [x] `show` notes rendered as plain text (HTML → text), and the event id moved to the last text column for readability
- [x] Shell completions — generated from the binary by `install.sh` (zsh + bash)
- [x] `README.md` — install, the independent-permission note, command reference, dates/durations, JSON scripting, troubleshooting
- [ ] Configuration — default calendar (config file and/or env var)
- [x] Versioning — SemVer git tags (`v0.2.0`); the `--version` string (main.swift) and Info.plist are bumped together by hand.
- [x] CI — GitHub Actions (`macos-latest`) builds and runs the pure suite (`swift run maccalCheck`) on push/PR. The live EventKit round-trip (`swift run maccalCheck --integration`) is **local-only** (needs a Calendar grant), so CI omits it. (Linux can't build at all: EventKit/AppKit.)

---

## Conventions

- All logic lives in `maccalCore` behind `CalendarStore` so commands are testable with no TCC/EventKit/network.
- Every command supports `--json` (NDJSON) for `jq`/LLM pipelines; human output is TSV.
- Add a `maccalCheck` case with each new behavior; keep the suite green.

## Review notes (deliberate choices from the M2 review)

- **Window flags are `--from`/`--to`** (macmail uses `--since`/`--until`). Chosen for clarity; `--since`/`--until`
  aliases could be added later. The upper bound is exclusive, matching macmail's `--until`.
- **Text mode is the human view; `--json` is the machine contract.** In text mode `agenda`/`search` may append a
  `(showing M of N …)` trailer to stdout, and `search --json` always emits a final `{"_summary":{…}}` line (even on
  zero matches). Pipelines should use `--json` (and `search --count-only`); neither carries the human trailer.
- **`show <id>` of a recurring event resolves the series anchor**, not the specific occurrence seen in agenda/search —
  an `eventIdentifier` carries no occurrence date. The record is flagged `recurring: true`. (A future occurrence-
  qualified token is deferred.)
- **The permission gate and the thin `main.swift` command wiring are untested by design** — they're bound to live TCC
  and `exit()`; the tested logic lives in the pure `run*` functions. See `Permission.swift`.

### From the M3 (write) review

- **Recurring `edit`/`rm` require `--all-occurrences`.** Since an id resolves a series to its anchor (not the seen
  occurrence), a per-occurrence write would silently hit the wrong one — so it's refused with a clear error until
  occurrence-qualified ids land.
- **Exit codes for writes:** `0` = wrote / dry-ran; `1` = nothing written (validation error, not-found, read-only,
  store failure, **declined prompt**, or non-TTY refusal); `2` = the permission gate. So `maccal rm X && next` won't run
  `next` on a decline.
- **`--json` is one shape across `add`/`edit`/`rm`** — the affected event as a single object (same as `show`), preserving
  `allDay`/`end`/`timeZone`. (`rm` no longer emits a bespoke `{deleted:…}` record.) `edit`'s *text* dry-run shows a
  before→after diff while success echoes the full event — intentional (a new event has no before-state).
- **`add --calendar` takes exactly one calendar** (a new event lives in one), unlike the repeatable `--calendar` union on
  `agenda`/`search`. `edit --calendar` (moving an event) is deferred.
- **A date-only `--start` (no `--end`/`--duration`) creates an all-day event**; all-day events need whole-day,
  date-only bounds (a clock time or sub-day `--duration` is rejected). The preview/`show` block surfaces `All-day: yes`.
- **all-day ↔ timed toggle on `edit` is deferred** — `edit` preserves an event's all-day-ness and snaps bounds to
  local midnight (DST-safe).
