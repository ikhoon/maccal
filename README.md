<p align="center">
  <img src="assets/maccal-logo.png" alt="maccal logo" width="150" height="150">
</p>

<h1 align="center">maccal</h1>

<p align="center">
  <b>A fast, scriptable macOS Calendar CLI</b> — with an optional menu-bar sync app.<br>
  List, search, add, edit, and mirror your calendar events from the terminal — no OAuth, no API tokens, no Full Disk Access.
</p>

<p align="center">
  <a href="https://github.com/ikhoon/maccal/actions/workflows/ci.yml"><img src="https://github.com/ikhoon/maccal/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center">
  <sub>Part of the <code>mac*</code> family ·
  <a href="https://github.com/ikhoon/macmail">macmail</a> (mail) ·
  <a href="https://github.com/ikhoon/macrec">macrec</a> (meeting recorder)</sub>
</p>

<p align="center">
  <img src="assets/demo-cli.gif" alt="maccal CLI demo — calendars, agenda, add, search" width="820">
</p>

Backed by **EventKit** — the local store macOS already syncs from your accounts —
so the only permission it needs is **Calendars**, granted to *maccal itself*
rather than your terminal.

- ⚡ **Fast** — reads the local EventKit store directly; no network.
- 🔒 **Minimal permission** — maccal holds its *own* Calendar grant (not the
  terminal's), so you don't expose every program in your terminal to your
  calendar. See [Calendar access](#calendar-access-one-time).
- 🤖 **Scriptable** — `--json` (NDJSON) on every command, made for `jq` / LLM
  pipelines. Destructive commands confirm by default and take `--yes` / `--dry-run`.
- 🗓️ **Full CRUD + sync** — `calendars` · `agenda` · `show` · `search` · `add` · `edit` · `rm` · `sync`.
- 🖥️ **Optional menu-bar app** — scheduled background calendar-to-calendar sync.
  See [Menu-bar app](#menu-bar-sync-app-maccalapp).

---

## Contents

- [Install](#install) · [Calendar access](#calendar-access-one-time)
- [Quick start](#quick-start) — copy-paste cheat sheet
- [Commands](#commands)
  - Read: [`calendars`](#calendars) · [`agenda`](#agenda) · [`show`](#show) · [`search`](#search)
  - Write: [`add`](#add) · [`edit`](#edit) · [`rm`](#rm) · [`sync`](#sync) · [`auth`](#auth)
- [Menu-bar sync app](#menu-bar-sync-app-maccalapp) — scheduled background sync
- [Dates & durations](#dates--durations) · [Scripting with JSON](#scripting-with-json) · [Shell completion](#shell-completion)
- [Troubleshooting](#troubleshooting) · [How it works](#how-it-works) · [Privacy](#privacy) · [Requirements](#requirements) · [Development](#development)

---

## Install

Universal (Apple Silicon + Intel). Homebrew is the easy path — its download isn't
quarantined, so there's no Gatekeeper prompt.

### Homebrew (recommended)

```console
$ brew install ikhoon/tap/maccal             # CLI only
$ brew install --cask ikhoon/tap/maccal-app  # CLI + menu-bar sync app
```

Both put `maccal` on your `PATH`, so pick one — the cask bundles the CLI. Then
authorize Calendar access once with `maccal auth` (see
[Calendar access](#calendar-access-one-time)); for the app, see the
[menu-bar app](#menu-bar-sync-app-maccalapp) section.

<details>
<summary><b>Other install methods</b> — release zip · from source</summary>

#### Download from Releases

Grab `maccal-<version>-macos-universal.zip` (CLI) or
`maccal-menubar-<version>-macos-universal.zip` (app) from the **Releases** page.
For the CLI:

```console
$ unzip maccal-<version>-macos-universal.zip
$ xattr -dr com.apple.quarantine maccal.app    # not notarized — clear Gatekeeper quarantine
$ mkdir -p ~/.local/lib ~/.local/bin
$ mv maccal.app ~/.local/lib/
$ ln -s ~/.local/lib/maccal.app/Contents/MacOS/maccal ~/.local/bin/maccal
```

The `xattr` step is only needed for a manual download (the build is ad-hoc signed,
not notarized); brew and a local build don't need it.

#### From source

```console
$ git clone https://github.com/ikhoon/maccal ~/src/maccal
$ cd ~/src/maccal
$ ./install.sh
```

`install.sh` compiles a release build, packages it as a `~/.local/lib/maccal.app`
bundle (its own row in Calendar privacy settings), codesigns it with a stable
identifier, symlinks the executable to `~/.local/bin/maccal`, and installs shell
completions. Requires the Swift toolchain (`xcode-select --install`). For a
distributable universal build, use `./release.sh` (CLI) or `./package.sh` (app).
Make sure `~/.local/bin` is on your `PATH`:

```console
$ which maccal        # → /Users/you/.local/bin/maccal
$ maccal --help
```

</details>

## Calendar access (one-time)

maccal needs Calendar access. For a CLI the grant would normally attach to your
*terminal* — giving every program in that terminal calendar access. maccal avoids
that: it's an app bundle and **disclaims TCC responsibility at startup**, so the
grant is keyed on `maccal.app`, not the launching terminal. Bootstrap it once,
interactively:

```console
$ maccal auth
```

A dialog titled **maccal** appears → click **Allow**. maccal now shows up under
*System Settings → Privacy & Security → Calendars* and works from **any** terminal
(Terminal.app, iTerm, cmux, VS Code, …) — no terminal-wide permission needed. The
stable codesign identifier means the grant survives rebuilds. To reset:
`tccutil reset Calendar kr.ikhoon.maccal`.

---

## Quick start

Everything you need for daily use. Copy, paste, adjust.

```bash
# SEE YOUR CALENDARS ────────────────────────────────────────────────────
maccal calendars                          # title · account · type · rw/ro · color
maccal calendars --writable               # only the ones you can edit

# AGENDA — what's coming up ──────────────────────────────────────────────
maccal agenda                             # next 7 days, all calendars
maccal agenda --from today --to +1d       # just today
maccal agenda --calendar Work --max 5     # one calendar, 5 rows
maccal agenda --from 2026-07-01 --to +3d  # an explicit window (3 days)

# SEARCH — find events by text ───────────────────────────────────────────
maccal search standup                     # match title/location/notes, ±30 days
maccal search 1:1 --in title              # titles only
maccal search review --from today --to +7d
maccal search incident --count-only       # totals only, no rows

# SHOW one event (id comes from agenda / search) ─────────────────────────
maccal show <id>                          # full detail (notes rendered as text)
maccal show <id> --json | jq .attendees

# ADD / EDIT / RM — preview with --dry-run, commit with --yes ─────────────
maccal add "Lunch" --start "tomorrow 12:00" --duration 1h --calendar Personal --dry-run
maccal add "Lunch" --start "tomorrow 12:00" --duration 1h --calendar Personal --yes
maccal add "PTO" --start 2026-07-01 --end 2026-07-04 --all-day --calendar Personal
maccal edit <id> --location "Room 4F"     # prompts; before→after diff with --dry-run
maccal edit <id> --start "tomorrow 16:00" # end shifts to keep the duration
maccal rm <id>                            # confirms before deleting

# FIRST-TIME SETUP ───────────────────────────────────────────────────────
maccal auth                               # grant maccal its own Calendar access
```

> **The `id`** in the last column of `agenda` / `search` output is what you pass
> to `show`, `edit`, and `rm`. Human output is TSV; add `--json` to any command
> for NDJSON.

---

## Commands

| | Commands | Notes |
|---|---|---|
| **Read** | `calendars` `agenda` `show` `search` | no side effects |
| **Write** | `add` `edit` `rm` | confirm by default; `--dry-run` / `--yes` |
| **Sync** | `sync` | one-way mirror into a target; idempotent |
| **Setup** | `auth` | grant Calendar access once |

Conventions: every command takes `--json` (NDJSON, for `jq`); `--calendar`
selects by title **or** identifier (case-insensitive); write commands take
`--dry-run` (preview) and `-y` / `--yes` (skip the prompt).

---

### `calendars`

List the calendars maccal can see — use a title as a `--calendar` selector.

```console
$ maccal calendars
Work          you@example.com     caldav         rw   #FFCC00
Personal      you@example.com     caldav         rw   #83D754
Holidays      Subscriptions       subscription   ro   #16A765
```

```bash
maccal calendars --writable     # only calendars you can modify
maccal calendars --source work  # filter by account (case-insensitive substring)
maccal calendars --json         # full records (identifier, sourceType, color)
```

---

### `agenda`

Events in a date window, soonest first. Columns: **when · [calendar] · title · id**
(the `calendar` column appears only when results span more than one).

```console
$ maccal agenda --from today --to +1d
2026-06-23T10:30:00+09:00   Standup         1A2B…/RID=…
2026-06-23T14:00:00+09:00   Design review   1A2B…@example.com
```

```bash
maccal agenda                                # next 7 days, all calendars
maccal agenda --calendar Work --calendar Personal   # union of calendars (repeatable)
maccal agenda --from 2026-07-01 --to +3d --max 10
maccal agenda --json | jq -r .title
```

| Flag | Default | Description |
|---|---|---|
| `--from` / `--to` | `[today, +7d)` | Window bounds (exclusive end); see [Dates](#dates--durations) |
| `--calendar <sel>` | all | Title or identifier; repeatable to union |
| `--max <n>` | `20` | Max rows (trailer reports the true total) |
| `--hide-cancelled` | — | Omit events with a cancelled status |
| `--json` | — | NDJSON |

---

### `show`

Print one event's full detail by id. HTML notes (Google/Exchange) render as
plain text.

```console
$ maccal show 1A2B…
Title:        Design review
When:         2026-06-23T14:00:00+09:00 — 2026-06-23T15:00:00+09:00
Calendar:     Work
Location:     Room 4F
Status:       confirmed
Availability: busy
Attendees:
  Sam <sam@example.com> — required/accepted

Agenda: walk through the new layout, then Q&A.
```

```bash
maccal show <id> --json | jq .attendees
maccal show "$(maccal agenda --json | jq -r .id | head -1)"   # today's first event
```

---

### `search`

Find events whose text matches within a window (default `[today-30d, +30d)`).

```console
$ maccal search standup --count-only
total: 8
examined: 41
```

```bash
maccal search standup                  # title/location/notes, ±30 days
maccal search 1:1 --in title --json
maccal search review --from today --to +7d
maccal search incident --count-only    # totals only, no rows
```

| Flag | Default | Description |
|---|---|---|
| `[query]` | — | Case-insensitive substring (required) |
| `--in <scope>` | `all` | `title` \| `location` \| `notes` \| `all` |
| `--calendar <sel>` | all | Title/identifier, repeatable |
| `--from` / `--to` | `[today-30d, +30d)` | Window bounds |
| `--max <n>` | `10` | Max rows |
| `--count-only` | — | Print totals, no rows |
| `--hide-cancelled` | — | Omit events with a cancelled status |
| `--json` | — | NDJSON; final line is `{"_summary": {…}}` |

---

### `add`

Create an event. Give `--start` plus exactly one of `--end` / `--duration`; a
date-only `--start` with neither makes an all-day event. Echoes the created event
back (like `show`).

```console
$ maccal add "Lunch" --start "tomorrow 12:00" --duration 1h --calendar Personal --dry-run
Title:        Lunch
When:         2026-06-21T12:00:00+09:00 — 2026-06-21T13:00:00+09:00
Calendar:     Personal
Status:       confirmed
Availability: busy
```

```bash
maccal add "Sprint planning" --start "tomorrow 10:00" --end "tomorrow 11:30" --location "Room 4"
maccal add "PTO" --start 2026-07-01 --end 2026-07-04 --all-day --calendar Personal
maccal add "Standup" --start "tomorrow 09:30" --duration 15m --tz Asia/Tokyo --yes
```

Flags: `--all-day`, `--calendar`, `--tz`, `--location`, `--notes`, `--url`,
`--availability busy|free|tentative|unavailable`, `--json`, `--dry-run`, `--yes`.

---

### `edit`

Update fields of an event by id. Moving `--start` alone shifts the end to keep
the duration; an empty string (`--notes ""`) clears a field.

```console
$ maccal edit 1A2B… --location "Room A" --dry-run
Location: Room 4F → Room A
```

```bash
maccal edit <id> --title "Renamed" --yes
maccal edit <id> --start "tomorrow 16:00"        # end shifts to keep duration
maccal edit <id> --notes "" --yes                # empty string clears the field
maccal edit <id> --calendar Personal --yes       # move the event to another calendar
maccal edit <id> --notes "Agenda attached" --all-occurrences   # whole recurring series
```

Flags: `--title`, `--start`/`--end`/`--duration`, `--location`/`--notes`/`--url`,
`--tz`, `--availability`, `--calendar` (move to another calendar),
`--all-occurrences`, `--json`, `--dry-run`, `--yes`.

---

### `rm`

Delete an event by id. Confirms by default (declined unless you type `y`).

```console
$ maccal rm 1A2B…
Title:        Lunch
When:         2026-06-21T12:00:00+09:00 — 2026-06-21T13:00:00+09:00
Calendar:     Personal
Delete this event? [y/N] y
deleted 1A2B… — Lunch
```

```bash
maccal rm <id> --dry-run          # show what would be deleted
maccal rm <id> --yes              # skip the prompt (required when piped)
maccal rm <id> --all-occurrences  # whole recurring series
maccal rm "<id>@<epoch>"          # skip ONE occurrence of a repeat (the id agenda/search prints)
```

---

### `sync`

One-way **mirror** one or more source calendars into a target over a date window.
Idempotent: re-run any time (or from `cron`/`launchd`) and it only adds new
events, updates changed ones, and removes ones whose source is gone. Only
maccal's own copies are touched — your other events in the target are left alone
(each copy carries a hidden marker in its url).

`--from` repeats, and a selector can be `"Account/*"` (an entire account),
`"Account/Calendar"` (to disambiguate a name shared across accounts), or a bare
title/identifier.

```console
$ maccal sync --from "Google/Team" --to "iCloud/Mirror" --dry-run
would sync: Team → Mirror   +3 new  ~0 changed  -0 removed
  + 2026-06-20T10:00:00+09:00  Standup
  + 2026-06-20T14:00:00+09:00  Design review
  + 2026-06-21T12:00:00+09:00  Lunch
```

```bash
maccal sync --from A --to B --yes                        # title + time + location
maccal sync --from A --from "Team Events" --to B --yes   # several sources → one target
maccal sync --from A --to B --notes --yes                # also copy the body
maccal sync --from A --to B --no-location --yes          # omit the location
maccal sync --from A --to B --until +14d --yes           # only the next 2 weeks
maccal sync --from A --to B --no-delete --yes            # never delete from target
```

Default window is today … +30d (override with `--since`/`--until`). Each copy
carries **title + time + location**; `--notes` also copies the body and
`--no-location` drops the location. Automate it with a `launchd`/`cron` job
running `maccal sync … --yes` — or let the [menu-bar app](#menu-bar-sync-app-maccalapp)
schedule it for you.

Flags: `--from` (repeatable), `--to`, `--since`/`--until`, `--notes`,
`--no-location`, `--no-delete`, `--json`, `--dry-run`, `--yes`.

---

### `auth`

Grant maccal its own Calendar access (run once, interactively). See
[Calendar access](#calendar-access-one-time).

```console
$ maccal auth        # a "maccal" dialog appears → click Allow
```

---

## Menu-bar sync app (maccal.app)

Not everyone wants to hand-write a `launchd` job. **maccal.app** is a menu-bar
companion that schedules `maccal sync` for you and keeps it running in the
background — set your calendars once and forget it.

A calendar icon with a small sync overlay sits in your menu bar. Click it for the
current status — the calendars you're mirroring, the target, and when the last
sync ran — plus **Sync now**, **Settings…**, and the toggles below.

### Settings

Open **Settings…** from the menu. Changes save immediately and the background job
re-registers itself on every change — no restart, no "apply".

| Setting | What it does | Default |
|---|---|---|
| **Sources** | Calendars to mirror **from** — a checkbox list, pick as many as you like | — |
| **Target** | The one calendar to mirror **into** (must be writable) | — |
| **Interval** | How often the background sync runs | 30 min |
| **Detail** | What each copy carries — **Title** (always on) plus **Location** and **Notes** toggles | Title + Location |

Once **Sources** and a **Target** are set, background sync just starts — there's
no "run in background" switch to remember. The menu shows the **last-synced** time
and a compact tally (`+N new  ~N changed  −N removed`), updated by both manual
**Sync now** runs and the scheduled `launchd` job (via a small shared last-sync
record, so background runs show up too).

### Menu toggles

| Toggle | What it does |
|---|---|
| **Keep awake for sync** | Holds an `IOPMAssertion` so the Mac won't **idle-sleep** and miss a scheduled sync. *(Closing the lid still sleeps — a macOS limitation.)* |
| **Start at login** | Registers the app as a login item, so it's back after every reboot. |

Both are custom menu items that **don't dismiss the menu when clicked** — flip
several in a row — while keeping the native look (SF Symbol, checkmark, hover
highlight).

### Why a bundled CLI?

The app **bundles the `maccal` CLI** and runs *that* copy for background sync:

- **No separate install.** The app is self-contained — you don't also need
  `brew install maccal`.
- **One Calendar grant.** The bundled CLI is signed with the app's identity, so it
  **shares the app's Calendar permission** instead of prompting — which a
  background job couldn't answer anyway.
- **Never out of step.** CLI and app ship together, so their sync-marker format
  and flags can't drift apart.

### Install the app

**Homebrew cask** (recommended) — installs the app **and** puts the bundled `maccal`
CLI on your `PATH`, so this one command gives you both the GUI and the terminal
command (updates with `brew upgrade`):

```console
$ brew install --cask ikhoon/tap/maccal-app
```

> Only want the terminal CLI, no app? Install the [formula](#homebrew-recommended)
> instead — `brew install ikhoon/tap/maccal`. Both put `maccal` on `PATH`, so pick
> one, not both.

**From source** — build a universal `maccal.app`, install to `/Applications`, launch:

```console
$ ./package.sh --install
```

Or download `maccal-menubar-<version>-macos-universal.zip` from **Releases**, unzip,
and drag `maccal.app` to `/Applications`.

### Calendar access for the app

The app holds its **own** Calendar grant, separate from the CLI's: it appears as its
own row (bundle id `kr.ikhoon.maccalbar`) under *System Settings → Privacy & Security
→ Calendars*, distinct from the CLI's `kr.ikhoon.maccal`. Launch the app once and
click **Allow** when prompted. The bundled CLI runs under the app's bundle, so it
shares this grant — background sync needs no separate prompt.

> **Two grants, on purpose.** The CLI (`maccal`, from your terminal) and the app
> (`maccal.app`, background sync) each carry their own Calendar permission, so
> revoking one leaves the other intact. Reset either with
> `tccutil reset Calendar kr.ikhoon.maccal` / `tccutil reset Calendar kr.ikhoon.maccalbar`.

---

## Dates & durations

`--from` / `--to` / `--start` / `--end` accept:

| Form | Example |
|---|---|
| Calendar date | `2026-07-01` |
| Keyword | `today` · `tomorrow` · `yesterday` |
| Signed offset | `+7d` · `-3d` · `+2w` |
| Timed | `2026-07-01T14:30` · `'2026-07-01 14:30'` · `'today 14:30'` · `'+1d 09:00'` |

`--duration` is a single unit or descending compound: `30m`, `1h`, `1h30m`, `2d`,
`1w2d`. Upper bounds are **exclusive**; a date-only start/end means all-day; day
math is DST-correct.

---

## Scripting with JSON

Every command supports `--json` (NDJSON — one object per line). Dates are UTC
ISO-8601 (`Z`) in JSON, local-with-offset in text. Every field is always present
(empty values are `""` / `[]` / `false`), so `jq` never hits a missing key.

```bash
# When + title of the next week's events
maccal agenda --json | jq -r '"\(.start)  \(.title)"'

# How many events match, without pulling rows
maccal search incident --count-only --json | jq '._summary.total'

# Delete every event matching a phrase (skip the _summary line)
maccal search "cancelled demo" --json \
  | jq -r 'select(._summary | not) | .id' \
  | xargs -I{} maccal rm {} --yes
```

---

## Shell completion

The binary sets this up itself (`install.sh` just calls it).

**zsh** — add one line to `~/.zshrc` (no files, no `fpath` setup):

```zsh
source <(maccal completions --shell zsh)
```

**bash / fish** — install to the standard `$XDG_DATA_HOME` location, loaded
automatically:

```console
$ maccal completions --install     # for your $SHELL
```

`install.sh` runs `maccal completions --install` for you. `--install` also works
for zsh if you'd rather have a file on your `fpath` (it prints the `fpath=(…)`
line to add before `compinit`).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| **"Calendar access denied / needs full access"** | Run `maccal auth` once in an interactive Terminal, click Allow. Reset with `tccutil reset Calendar kr.ikhoon.maccal`. |
| **"this is a recurring event"** | `edit` on a recurring series needs `--all-occurrences`. To skip a single occurrence, `rm` the `id@epoch` handle that agenda/search print for recurring rows. |
| **"the event's calendar is read-only"** | Subscribed/holiday calendars can't be modified — pick a writable one (`maccal calendars --writable`). |
| **"refusing to … without --yes"** | Non-interactive (piped/cron) writes need `--yes`; there's no TTY to confirm on. |
| **`maccal: command not found`** | `~/.local/bin` (source) or `/opt/homebrew/bin` (brew) isn't on `PATH`. Check with `which maccal`. |
| **Background sync doesn't run** | Open the [menu-bar app](#menu-bar-sync-app-maccalapp), set sources + a target, grant it Calendar access. Enable "Keep awake for sync" if the Mac idles. |

---

## How it works

> Skip this unless you're curious or hacking on maccal.

Everything goes through **EventKit** — the same local store the Calendar app uses,
which macOS already syncs from your accounts. maccal never talks to a calendar
server itself.

```
maccal <subcommand>
   │  (re-execs once to disclaim TCC responsibility, then…)
   ├── read paths  ─► EKEventStore  (local store; no network)
   └── write paths ─► EKEventStore.save / .remove  (commit immediately)

maccal.app (menu-bar)
   └─ launchd job ─► maccal sync … --yes  (bundled CLI, on your interval)
```

**Design notes** — the deliberate choices maccal is built around:

- **Calendar access is keyed to maccal, not your terminal.** maccal is an `.app`
  bundle and **disclaims TCC responsibility** at startup (a one-shot `posix_spawn`
  re-exec), so macOS attributes the grant to `maccal.app` — its own row in
  Settings, usable from every terminal (Terminal, iTerm, VS Code, …).
- **The menu-bar app bundles the CLI.** Background sync shells out to the copy of
  `maccal` inside `maccal.app`, signed with the app's identity so it **shares the
  app's Calendar grant** — no separate `brew install`, no second prompt.
- **Sync only ever touches its own copies.** Each mirrored event carries a hidden
  marker in its URL (`maccal-sync://<epoch>/<srcId>`), so re-runs add/update/delete
  exactly maccal's copies and never your real events in the target.
- **Recurring series resolve to their anchor.** An `eventIdentifier` carries no
  occurrence date, so `edit`/`rm` on a repeat require `--all-occurrences` rather
  than silently hitting the wrong instance.
- **Date math is DST-correct.** Windows, durations, and keep-duration edits add
  calendar components (not raw seconds), so a 1h meeting stays 1h across a
  spring-forward boundary.
- **All logic sits behind a `CalendarStore` protocol**, unit-tested against an
  in-memory fake — no TCC, EventKit, or network in the test suite.

*Non-goals: reminders, server-side rules, account management.*

<details>
<summary>Per-command internals</summary>

- **`calendars`** — `EKEventStore.calendars(for: .event)`, mapped to title /
  account / source-type / writability / color; `--source` filters by account.
- **`agenda` / `search`** — one bounded `events(in:calendars:)` fetch, then pure
  filtering/sorting; `search` substring-matches the mapped DTOs (title/location/
  notes) since EventKit has no text predicate for events.
- **`show`** — resolves one event by id; HTML notes (Google/Exchange) render to
  plain text.
- **`add` / `edit` / `rm`** — build a sparse `EventDraft`/`EventChanges`, gate on
  a write grant, confirm (or `--yes`), then `save`/`remove`; `edit` shows a
  before→after diff on `--dry-run`.
- **`sync`** — fetches source + target over the window, matches by URL marker,
  computes add/update/delete; a recurring source mirrors as one rule-bearing
  event, not one copy per occurrence.

</details>

---

## Privacy

maccal is local-first — nothing about your calendar leaves your machine.

- **No network.** Everything goes through EventKit's local store; maccal never
  contacts a calendar server, API, or telemetry endpoint.
- **Minimal, self-owned permission.** The only grant is Calendars, keyed to
  `maccal.app` (and separately the menu-bar app) — not your terminal.
- **maccal stores nothing of its own.** Settings live in the app's `UserDefaults`
  plus a tiny last-sync record; there's no database or cache of your events.

---

## Requirements

- **Running it:** macOS 14 (Sonoma) or later — Apple Silicon or Intel (the release
  build is universal). Nothing else: no network, no tokens.
- **Building from source:** the Swift toolchain (`xcode-select --install`).

---

## Development

```console
$ swift build              # build
$ swift run maccalCheck    # run the pure test suite (no Calendar access needed)
```

`maccalCheck` is a dependency-free harness (XCTest/swift-testing aren't needed),
driving the pure `run*` functions against `FakeCalendarStore`. EventKit, TCC, and
the CLI wiring are macOS-only and verified by hand; the suite covers the parsing,
filtering, formatting, and command logic.

<details>
<summary>Project layout</summary>

```
maccal/
├── Sources/
│   ├── maccalCore/               # all logic (testable; no @main / EventKit needed)
│   │   ├── Commands/             # one runX function per subcommand
│   │   ├── CalendarStore.swift   # protocol seam + EventInfo/EventDraft DTOs
│   │   ├── EKCalendarStore.swift # the real EventKit-backed store
│   │   ├── Sync.swift  SyncAgent.swift  SyncStatus.swift  AppVersion.swift
│   │   └── DateWindow.swift  DateTime.swift  Output.swift  Permission.swift
│   ├── maccal/                   # thin ArgumentParser CLI wiring (@main)
│   ├── maccalbar/                # menu-bar app (AppKit, NSStatusItem)
│   └── maccalCheck/              # dependency-free test harness
├── release.sh                    # universal CLI .app → dist zip (formula artifact)
├── package.sh                    # menu-bar app + bundled CLI → dist zip (cask); --install
└── Package.swift  Info.plist  ROADMAP.md
```

</details>
