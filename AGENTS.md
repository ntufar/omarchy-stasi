# omarchy-stasi — agent notes

Omarchy bar plugin (`io.github.ntufar.stasi`): Athens OASA bus arrivals in the
bar. Quickshell QML display + Python helper (`bin/stasi-client` shim).
Companion to Stasi for Android (github.com/ntufar/stasi) — same API contract;
Kotlin sources there are the reference for ports (OasaApi.kt, GreekText.kt,
SearchViewModel.kt).

## Layout

- `manifest.json` — plugin contract, must stay at repo root (installer clones root).
- `src/BarWidget.qml` — bar pill, 30 s poll, panel hosting.
- `src/Panel.qml` — arrival board + stop search + preview.
- `src/Model.js` — pure display math (no Quickshell imports).
- `stasi_client/` — stdlib-only helper: `oasa.py` (HTTPS, throttle, caches,
  stop index, search), `greek.py` (GreekText.kt port), `__main__.py` CLI.
- `tests/` — stdlib unittest, offline only (fixtures, stubbed `_post`).
- `docs/OMARCHY_PLUGIN.md` — architecture + phased plan.

## Commands

```bash
python3 -m unittest discover -s tests
omarchy plugin validate .
mkdir -p /tmp/qmlimports/qs
ln -sfn /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui /tmp/qmlimports/qs/
/usr/lib/qt6/bin/qmllint -I /tmp/qmlimports src/BarWidget.qml src/Panel.qml
./bin/stasi-client arrivals --stop <code>
./bin/stasi-client search <greek|greeklish|code>
./bin/stasi-client refresh-stops   # one-time index build, ~30 min cold (1.2 s throttle)
```

## Helper contract (QML depends on this)

- One invocation → one JSON doc on stdout, exit 0. Errors → `{"error": msg}`
  on stdout, nonzero exit. Never break this shape.
- `arrivals` payload: `{"stops": [per-stop payloads...], "fetched_at"
  (oldest snapshot), "arrivals" (merged, known minutes first), "cached"}`.
  Each arrival adds friendly `line`/`destination` and owning `stop` keys.
  One failing stop yields an `{"error"}` section, not a failed call.
- `search` needs a built index (`~/.cache/io.github.ntufar.stasi/stops_index.json`);
  without it, it errors with a `refresh-stops` hint. Panel surfaces that string.
- Rate limit ~1 req/1.2 s per endpoint (enforced in `oasa._throttle`); caches:
  arrivals ~20 s, lines/routes/stops ~24 h. No network in tests.

## QML gotchas (learned the hard way)

- `Process`/`StdioCollector` need `import Quickshell.Io` in every file that uses
  them (qmllint catches this — BarWidget had it, Panel didn't).
- `PanelKeyCatcher` runs `Keys.priority: BeforeItem` and swallows
  h/j/k/l/x/Space/Enter — suspend with `blocked: <field>.activeFocus` while
  typing (weather-panel precedent) + `Keys.onEscapePressed: root.close()`.
- Helper path: `bar.barWidgetRegistry.metadataFor(id).sourceDir + "/bin/stasi-client"`.
- `setting("key", default)` reads shell.json bar-entry keys.
- qmllint warnings that are benign here: `missing-property` on dynamic `bar`,
  `unqualified` in Repeater delegates, `QProcess::ExitStatus` on `onExited`.
  Zero `Error` lines is the gate. omarchy-shell is not running in dev, so QML
  is lint-reviewed, not live-tested.

## Conventions

- Match Android semantics on ports; document deliberate deviations in code
  (e.g. search ranks code-prefix first; Android DAO order is unordered).
- Multi-word Greeklish does not expand (parity with `GreekText.kt`: Latin-only,
  single token); multi-word Greek works.
- No committed `__pycache__`/`.pyc` (gitignored). No new test framework.

## Git

- `master` tracks `origin/master`; history is linear (rebased 2026-09-09).
- Do not commit, push, rebase, or merge without an explicit ask in the session.

## Roadmap (from docs/OMARCHY_PLUGIN.md)

Done: scaffold, arrivals, widget, board, stop search (+ preview), watchlist,
alerts. Next: maintenance only.
Out of scope: GPS nearby, route map, timetable.
