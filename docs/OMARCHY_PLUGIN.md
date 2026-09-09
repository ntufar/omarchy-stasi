# Stasi as an Omarchy Plugin — Architecture & Implementation Plan

Status: phases 0–3 + stop search implemented and live-verified (2026-09-09).
Remaining: watchlist/multiple-stop settings, alerts.
Date: 2026-09-09.

## 1. Verdict

**Yes, it is possible**, but not as a port of the Android app. Omarchy shell
plugins are **Quickshell (QML + JS) bar widgets/panels** backed by small helper
programs — Kotlin code cannot run inside `omarchy-shell`. The viable shape is a
new, small native plugin — `io.github.ntufar.stasi` — that reuses Stasi's OASA
API contract and product logic, with a Python helper doing the networking and
QML doing the display.

What was verified on this machine (Omarchy installed, shell sources readable):

- Plugin contract: `manifest.json` with `schemaVersion: 1`, required fields
  `id/name/version/kinds/entryPoints`; `omarchy plugin validate <dir>` checks it.
- `id` must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and **must not** use the reserved
  `omarchy.*` namespace → `io.github.ntufar.stasi` (same as the Android package).
- Known `kinds`: `bar`, `bar-widget`, `panel`. A widget+popup needs
  `kinds: ["bar-widget", "panel"]` with entry points `barWidget` + `panel`
  (pattern proven by `panels/clock` and the third-party `news-radar` plugin).
- Install/enable flow: `omarchy plugin add <git-url> --enable`,
  `omarchy bar put io.github.ntufar.stasi`, `omarchy restart shell`.
  User plugins live in `~/.config/omarchy/plugins/<id>/` and hot-reload on save.
- Established pattern for data-fetching widgets: QML `Timer` + Quickshell
  `Process` spawning a helper binary that prints JSON
  (cf. `SystemUpdate.qml` polling `omarchy-update-available`,
  `news-radar` spawning `bin/news-radar-client`, a Python CLI).
- Per-widget settings live in `~/.config/omarchy/shell.json` bar entries and are
  read in QML via `setting("key", default)` (cf. `clock/BarWidget.qml`).

One limitation: `omarchy-shell` was not running in this session, so hot-reload
behavior is taken from sources/docs, not observed live.

## 2. Architecture

### 2.1 Plugin repository layout (new repo, e.g. `ntufar/omarchy-stasi`)

```
omarchy-stasi/
  manifest.json            # id io.github.ntufar.stasi, kinds bar-widget+panel
  src/
    BarWidget.qml          # bar pill: next bus "740 · 4'" for watched stop(s)
    Panel.qml              # popup: arrival board for watched stops
    Model.js               # formatting, countdown math, GreekText port helpers
  bin/
    stasi-client           # bash shim -> python3 -B -m stasi_client (news-radar pattern)
  stasi_client/
    __main__.py            # CLI: arrivals <stop> | search <q> | indicator
    oasa.py                # OASA HTTP layer (port of OasaApi.kt + rate limiter)
    greek.py               # accent-insensitive normalization (port of GreekText.kt)
  assets/
    io.github.ntufar.stasi.svg
  README.md
```

### 2.2 Runtime data flow

```
Timer (30 s, only while bar visible)
  -> Process runs `stasi-client arrivals --stop <code> --json`
  -> helper: disk cache check (~/.cache) -> POST https://telematics.oasa.gr/api/?act=getStopArrivals&p1=<code>
  -> stdout JSON -> QML parses -> bar label + panel list update
```

Design rules borrowed from the reference plugins:

- **Helper is stateless and synchronous**: one invocation, one JSON document on
  stdout, exit code 0. All scheduling/caching display logic stays in QML/JS.
- **Throttle at the helper**: OASA allows ~1 req / 1.2 s per endpoint per user
  ([SPEC.md](https://github.com/ntufar/stasi/blob/main/docs/SPEC.md) §6). Enforce in `oasa.py` (same role as
  `EndpointRateLimiter.kt`) plus a ~20 s arrivals disk cache, mirroring the
  Android short-freshness window. Never let the QML timer fire faster than the
  limiter allows.
- **State/cache locations**: `XDG_STATE_HOME` for favorites/watchlist,
  `XDG_CACHE_HOME` for API snapshots (same convention as `news-radar`).
- **Settings via shell.json**: watched stop codes + alert threshold stored as
  bar-entry keys, read with `setting()` and written back with
  `bar.shell.updateEntryInline` (clock pattern), so config survives restarts.

### 2.3 Feature mapping (Android → plugin)

| Android (Stasi) | Plugin scope |
| --- | --- |
| Arrivals screen (big minutes, freshness) | Panel.qml arrival board, 30 s poll, relative freshness label |
| Home favorites (2 arrivals/stop) | Watchlist of stop codes; bar pill shows nearest arrival, panel shows all |
| Search (Greek fuzzy + Greeklish) | `stasi-client search` in helper; panel search field; port `GreekText.kt` |
| Arrival alerts (WorkManager, ≤ threshold min) | Phase 2: helper exit + `notify-send` / reminder hook when minutes ≤ threshold |
| Nearby (GPS), route map (MapLibre), timetable | **Out of scope** — no GPS/map stack in bar widgets; panel links out (`xdg-open` OASA/web map) instead |
| Offline 24 h lines/stops cache | Disk-cached stop-name lookup only (for panel headers) |

Countdown behavior (§3 of SPEC.md — wall-clock countdown between polls every
~15 s) is reproduced in `Model.js` from the snapshot timestamp, so the bar does
not look stuck when OASA repeats an ETA.

### 2.4 What is deliberately NOT reused

- No Kotlin/JVM in the plugin (Quickshell cannot load it; Waydroid-shipped APK
  was considered and rejected — heavier, no bar integration).
- No Room/DataStore/WorkManager — replaced by JSON files + QML Timer.
- No MapLibre — no map surface in the shell bar.

## 3. Implementation plan

- [ ] **Phase 0 — scaffold (0.5 day).** Clone `panels/clock` structure into
  `omarchy-stasi/`; write `manifest.json`; `omarchy plugin validate ./omarchy-stasi`
  must exit 0. Acceptance: installs via `omarchy plugin add <path> --enable`
  (or manual copy to `~/.config/omarchy/plugins/`) and appears in bar.
- [ ] **Phase 1 — helper + `getStopArrivals` (1–2 days).** Port `OasaApi.kt`
  `getStopArrivals` (+ DTOs from `OasaDto.kt`, arrival parsing from
  `ArrivalParsing.kt`) to `stasi_client/oasa.py` with the 1.2 s rate limiter and
  User-Agent `Stasi-Omarch/1.0`. CLI outputs stable JSON. Acceptance: unit test
  with a recorded OASA response; manual run prints arrivals for a known stop
  (e.g. ΣΥΝΤΑΓΜΑ).
- [ ] **Phase 2 — BarWidget (1 day).** Pill shows `line · minutes` of the next
  arrival for the configured stop; click opens panel; QML `Timer` 30 s refresh
  guarded by `process.running`. Acceptance: bar updates without shell errors
  (`journalctl --user -u omarchy-shell` clean).
- [ ] **Phase 3 — Panel board (1–2 days).** Full arrival list, stop switcher for
  the watchlist, freshness stamp, error line on fetch failure (localized EN/EL
  strings like the app). Acceptance: matches Android arrivals for the same stop
  within one poll interval.
- [ ] **Phase 4 — settings + search (1–2 days).** Watchlist editing persisted to
  shell.json entry (open); `search` subcommand with `GreekText.kt`
  normalization port (done 2026-09-09: `stasi-client search`, cached
  `stops_index.json` via `refresh-stops`, panel search field + tap-to-preview).
  Acceptance: Greeklish query `syntagma` finds ΣΥΝΤΑΓΜΑ (verified live).
- [x] **Phase 5 — alerts (1 day).** `alertThreshold` setting (0 = off) +
  `stasi-client alerts` transition check after each poll, one `notify-send`
  summary per cycle, no repeats while the bus stays on the board.
  Acceptance: `omarchy plugin validate` green (verified).
- [ ] **Polish (optional).** README install from clean `git clone`; icon asset
  review; theme check after each `omarchy update` (Quickshell API drift).

Total estimate: **~1 week** for phases 0–4, plus 1–2 days for phase 5.

## 4. Distribution: why a separate repo is required

`omarchy plugin add <git-url>` does a plain `git clone` of the URL into a
staging dir, then runs `omarchy-plugin-validate` **on the clone root** — so
`manifest.json` must sit at the repository root, and the folder is installed
verbatim to `~/.config/omarchy/plugins/<id>/`. There is no `--subdir` option.

Consequences for Stasi:

- The Android repo **cannot** serve as the plugin repo as-is: putting a
  `manifest.json` at its root would make every install clone the full Android
  project (Gradle wrapper, MapLibre natives, build dirs) as dead weight, and
  every `omarchy plugin update` would pull Android history.
- A monorepo-with-subdirectory layout is **not supported** by the installer.
- So: create a dedicated repo (e.g. `ntufar/omarchy-stasi`) containing only the
  layout in §2.1. Install then works exactly like other community plugins:

```bash
omarchy plugin add https://github.com/ntufar/omarchy-stasi.git --enable
omarchy bar put io.github.ntufar.stasi
omarchy restart shell
```

This also matches ecosystem convention (news-radar, adguard, espanso are all
single-purpose repos) and gives the plugin independent versioning from the
Android app's `versionName`/`CHANGELOG.md` release train.

## 5. Risks & open questions

1. **OASA from desktop networks** — the Android app uses the same public
   endpoint, but desktop-IP throttling is untested; the rate limiter + cache
   mitigate it. Verify with real polling before promising 30 s freshness.
2. **Quickshell API drift** — pin against the installed shell (`qs.Commons`,
   `qs.Ui` imports as in `SystemUpdate.qml`); re-validate after each
   `omarchy update`.
3. **Scope creep (map/timetable)** — explicitly out; if wanted later, ship as a
   separate launcher app, not a bar widget.
4. **Testing** — `news-radar` ships a `Makefile`/CI test target; copy that for
   helper unit tests. QML has no unit harness — validate by install + log watch.

## 6. Sources consulted

- `/usr/share/omarchy/shell/services/PluginRegistry.qml` (kinds/manifest rules)
- `/usr/share/omarchy/shell/plugins/bar/manifest.json`,
  `bar/widgets/SystemUpdate.qml` (polling-widget pattern)
- `/usr/share/omarchy/shell/plugins/panels/clock/` (widget template, settings pattern)
- `~/.config/omarchy/plugins/io.github.mtolhuys.news-radar/` (Python-helper precedent)
- `omarchy plugin --help`, `omarchy bar --help`, `omarchy-plugin-validate` source
- Stasi: `app/src/main/java/io/github/ntufar/stasi/data/api/OasaApi.kt`, [SPEC.md](https://github.com/ntufar/stasi/blob/main/docs/SPEC.md)
