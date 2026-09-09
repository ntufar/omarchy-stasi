---
name: stasi-helper-contract
description: Helper CLI/JSON contract and QML wiring patterns for the omarchy-stasi plugin (Process fetching, search index, panel key handling).
---

# Stasi Helper Contract

The QML shell and the Python helper meet at one boundary: `bin/stasi-client`
(stdout JSON, exit codes). Keep both sides of it in sync.

## CLI surface (`stasi_client/__main__.py`)

- `arrivals --stop <code> [--force-refresh]` →
  `{"stop", "fetched_at" (epoch seconds), "arrivals": [...], "cached"}`.
  Each arrival carries raw OASA fields plus friendly `line` (= `line_code`)
  and `destination` (= `route_descr`) keys added by the CLI layer.
- `search <query> [--limit N]` (default 120) →
  `{"query", "stops": [{"stop_code", "descr"}]}`.
- `refresh-stops [--full]` → `{"built_at", "stops", "lines", "routes"}` on
  stdout, per-line progress on stderr.
- Every failure: `{"error": msg}` on stdout, nonzero exit. QML parses stdout
  as JSON in both cases — never print tracebacks or logs to stdout.

## Data layer (`stasi_client/oasa.py`, stdlib only)

- Endpoint: `POST https://telematics.oasa.gr/api/?act=<act>&p1=...`, empty body,
  `User-Agent: Stasi-Omarch/1.0`. Acts used: `getStopArrivals`, `webGetLines`,
  `webGetRoutes`, `webGetStops`. OASA has no text search — the corpus is a
  crawled `stops_index.json` under
  `$XDG_CACHE_HOME/io.github.ntufar.stasi` (Android 24 h catalog parity).
- Throttle: max ~1 request / 1.2 s per endpoint (`_throttle`); never bypass it
  for speed. TTLs: arrivals ~20 s, catalog levels ~24 h.
- Search semantics (port of `OasaRepository.searchStops` + `GreekText.kt`):
  Latin-only queries expand Greeklish → accent-strip → lowercase, min 2 chars,
  `%`/`_` scrubbed, substring match on `code + descr`. Deliberate deviation:
  stop-code-prefix hits rank before name-prefix before substring (Android DAO
  order is unordered). Multi-word Greeklish does not expand — parity, not a bug.

## QML wiring (`src/`)

- Fetch pattern: `Process` + `StdioCollector { waitForEnd: true }`, parse in
  `onExited`, guard with `proc.running` before starting. Helper path:
  `bar.barWidgetRegistry.metadataFor(moduleName).sourceDir + "/bin/stasi-client"`.
- `import Quickshell.Io` is required in each file using `Process`.
- Panel search: 250 ms debounce → `search --limit 8` → results list; tap runs
  `arrivals --stop <code>` into preview state, never touching the watched stop.
- `PanelKeyCatcher` uses `Keys.priority: BeforeItem` and eats h/j/k/l/x, Space,
  Enter — suspend it with `blocked: <searchField>.activeFocus` while typing and
  add `Keys.onEscapePressed: root.close()` to the field.
- `Model.js` stays import-free (pure functions) so its math is portable.
- Reference ports live in the Android repo (branch `master`): `OasaApi.kt`,
  `data/util/GreekText.kt`, `ui/search/SearchViewModel.kt`, `data/api/OasaDto.kt`.
