---
name: omarchy-plugin-checks
description: Run the verification gates for the omarchy-stasi plugin (unit tests, manifest validation, QML lint, live CLI probes).
---

# Omarchy Plugin Checks

Run these gates from the repo root after touching Python, QML, or the manifest.
All must pass before handing work back.

## 1. Python tests (offline, stdlib unittest)

```bash
python3 -m unittest discover -s tests
```

Tests live in `tests/`, use recorded fixtures and a stubbed `oasa._post` —
no network. New behavior needs a matching test in the existing layout.

## 2. Manifest validation

```bash
omarchy plugin validate .
```

Must exit 0. Only checks the manifest, not QML.

## 3. QML lint

`qmllint` ships with `qt6-declarative` at `/usr/lib/qt6/bin` (not on PATH).
The shell's `qs.Commons`/`qs.Ui` modules live as bare subdirs of
`/usr/share/omarchy/shell`, so map the dotted names with a shim first:

```bash
mkdir -p /tmp/qmlimports/qs
ln -sfn /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui /tmp/qmlimports/qs/
/usr/lib/qt6/bin/qmllint -I /tmp/qmlimports src/BarWidget.qml src/Panel.qml
```

Gate: zero `Error` lines, exit 0. These warnings are benign here (same patterns
in pre-existing shell code): `missing-property` on the dynamic `bar` object,
`unqualified` inside Repeater delegates, `QProcess::ExitStatus` on `onExited`,
`unused-imports` Info on `Quickshell`. A missing-type warning naming a
`Quickshell.Io` type (`Process`, `StdioCollector`) means the file lacks
`import Quickshell.Io` — a real runtime bug, fix it.

## 4. Live CLI probes (need network + built index)

```bash
./bin/stasi-client arrivals --stop 60718 | head -c 300
./bin/stasi-client search syntagma --limit 3
```

`search` without `~/.cache/io.github.ntufar.stasi/stops_index.json` must print
`{"error": "... refresh-stops ..."}` and exit 1. Rebuild the index with
`./bin/stasi-client refresh-stops` (cold crawl takes ~30 min at the 1.2 s
endpoint throttle; run it in the background and keep working).

Note: `omarchy-shell` does not run in dev sessions, so QML is lint-reviewed,
not live-rendered — say so in the handoff instead of claiming it was seen.
