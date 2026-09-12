---
name: stasi-helper-contract
description: Helper CLI/JSON contract and QML wiring patterns for the omarchy-stasi plugin (Process fetching, search index, panel key handling).
---

# Stasi Helper Contract

The QML shell and the Python helper meet at one boundary: `bin/stasi-client`
(stdout JSON, exit codes). Keep both sides of it in sync.

## CLI surface (`stasi_client/__main__.py`)

- `arrivals --stop <code> [--stop ...] [--force-refresh]` →
  `{"stops": [per-stop payloads...], "fetched_at" (oldest snapshot),
  "arrivals" (merged, known minutes first), "cached"}`.
  Each arrival carries raw OASA fields plus friendly `line` (= `line_code`),
  `destination` (= `route_descr`) and owning `stop` keys. One failing stop
  yields an `{"error"}` section instead of failing the whole call.
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
  `onExited`, guard with `proc.running` before starting. Helper path: resolved
  from `BarWidget.qml`'s own file location — `Qt.resolvedUrl("../bin/stasi-client")`
  with the `file://` scheme stripped and percent-encoding decoded. Do **not**
  go back to `bar.barWidgetRegistry.metadataFor(moduleName).sourceDir`: the
  `PluginBarApi` facade given to third-party bar widgets never exposes
  `barWidgetRegistry` (see `Ui/PluginBarApi.qml` in the Omarchy shell), so
  that lookup silently returns `""` forever and every helper call — arrivals,
  search, map tiles — no-ops with no error anywhere.
- `alerts --stop ... --threshold N [--notified k,...]` → `{"threshold",
  "notify" (due, unfired arrivals), "notified" (updated fired-key set)}`;
  `<=0` disables without fetching. Widget runs it after each arrivals fetch
  (shares the 20 s cache) and fires one `notify-send` summary per cycle;
  `alertThreshold` setting, `0` = off.
- Map data: `search-lines <q>` (line id/code/name, limit 80),
  `line-stops --line <code>` (routes + stops with lat/lng),
  `stops-geo [--limit N]` (indexed stops with coordinates; errors with the
  `refresh-stops` hint when the index was never built). Index entries carry
  `lat`/`lng` since the coords rebuild — older indexes need
  `refresh-stops --full` before markers appear.
- Map data feeds a pure-QML tile map (no WebEngine — it crash-loops the
  shell, see AGENTS.md). Stop dots come from `stops-geo`, line overlays from
  `line-stops`; all projection math lives in `Model.js` (slippy formulas).
  `overlayGeo` is an array of routes (each an ordered stop array), not a
  flat list — `updateMarkers` draws one `Shape`/`PathPolyline` per route
  under the stop dots, and flattening it back loses that grouping and lets
  the line jump between two different directions' stops.
- `map-tiles --tile z/x/y [--tile ...] --style light|dark [--force-refresh]`
  → `{"tiles": [{"z","x","y","style","path"} or {"z","x","y","error"}]}`.
  Fetches OSM raster tiles with `oasa.USER_AGENT` and disk-caches them
  (`stasi_client/tiles.py`) — required because `tile.openstreetmap.org`
  418-blocks requests with no identifying User-Agent (osm.wiki/Blocked).
  Never point `Image.source` at the remote tile URL; `Panel.qml` always
  batches through this and uses the returned `file://` path. `--style dark`
  fetches the same OSM tile and inverts its palette lightness locally
  (`tiles.darken_tile`) rather than hitting a separate dark basemap
  provider — every free one tried (CARTO's basemaps.cartocdn.com included)
  now demands an API key for anonymous raster requests and stamps a
  watermark over the tile instead. `Panel.qml` picks light vs. dark from
  the popup background's luma (`root.mapDark`) and keys its in-memory tile
  cache by `z/x/y:style` so the two styles never collide.
- Panel layout is tabbed (`root.activeTab`, "board" | "map"), not the old
  permanent side-by-side split — a fixed 50/50 pane read as a hard wall
  down the panel and left each side too narrow. `previewStop` switches to
  "board", `showLineOverlay` switches to "map"; `mapViewWidth` is bound to
  the rendered `mapCol.width`, not a second copy of the panel's content-area
  math, so the tile canvas can't silently drift out of sync with it and
  overflow the panel's edge.
- Watchlist: `setting("stops", [])` (array; strings tolerated) with legacy
  `setting("stop", "")` fallback, normalized by `Model.parseStops`. `saveStops`
  writes `{id, ...settings, stops: [...]}` via `updateEntryInline` and clears
  legacy `stop` so removals stick; panel calls `hostWidget.watchStop` /
  `unwatchStop`, never writes settings directly.
- `import Quickshell.Io` is required in each file using `Process`.
- Panel search: 250 ms debounce → `search --limit 8` → results list; tap runs
  `arrivals --stop <code>` into preview state, never touching the watched stop.
- `PanelKeyCatcher` uses `Keys.priority: BeforeItem` and eats h/j/k/l/x, Space,
  Enter — suspend it with `blocked: <searchField>.activeFocus` while typing and
  add `Keys.onEscapePressed: root.close()` to the field.
- `Model.js` stays import-free (pure functions) so its math is portable.
- Reference ports live in the Android repo (branch `master`): `OasaApi.kt`,
  `data/util/GreekText.kt`, `ui/search/SearchViewModel.kt`, `data/api/OasaDto.kt`.
