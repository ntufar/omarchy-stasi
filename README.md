# omarchy-stasi

Athens public-transport arrivals (OASA Telematics) in the Omarchy bar.
Companion to [Stasi for Android](https://github.com/ntufar/stasi) — same API
contract and product logic, rebuilt as a native shell plugin.

Bar pill shows the next arrival at your watched stop (`740 · 4ʹ`); click opens
the arrival board. Polls every 30 s with wall-clock countdown between polls.

## Install

```bash
omarchy plugin add https://github.com/ntufar/omarchy-stasi.git --enable
omarchy bar put io.github.ntufar.stasi
omarchy restart shell
```

## Configure

```bash
# Watch a stop (OASA stop code)
omarchy bar set io.github.ntufar.stasi stop 060123
```

## Layout

```
manifest.json            # plugin contract (id io.github.ntufar.stasi)
src/BarWidget.qml        # bar pill + 30 s poll + panel hosting
src/Panel.qml            # arrival board popup
src/Model.js             # countdown math + labels (port of ArrivalParsing.kt)
bin/stasi-client         # shim -> python3 -B -m stasi_client
stasi_client/oasa.py     # OASA HTTPS layer + 1.2 s rate limit + 20 s cache + stop index/search
stasi_client/greek.py    # Greek search normalization (port of GreekText.kt)
tests/                   # stdlib unittest, no network
docs/OMARCHY_PLUGIN.md   # architecture + implementation plan
```

## Develop

```bash
omarchy plugin validate ./omarchy-stasi
python3 -m unittest discover -s tests
# qmllint ships with qt6-declarative at /usr/lib/qt6/bin (not on PATH).
# The qs.* shim maps the shell's module names onto its subdirs.
mkdir -p /tmp/qmlimports/qs
ln -sfn /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui /tmp/qmlimports/qs/
/usr/lib/qt6/bin/qmllint -I /tmp/qmlimports src/BarWidget.qml src/Panel.qml
PYTHONPATH=. python3 -B -m stasi_client arrivals --stop 060123
# One-time stop-search index (slow cold crawl: lines -> routes -> stops).
# Panel search reports "stop index missing" until this has run once.
./bin/stasi-client refresh-stops
./bin/stasi-client search syntagma
```

Saves under `~/.config/omarchy/plugins/` hot-reload; otherwise
`omarchy-shell shell rescanPlugins`.

## Roadmap

Stop search is in: the panel has a search field backed by
`stasi-client search` (Greek, Greeklish, or stop code) over a cached stop
index — build it once with `stasi-client refresh-stops`. Tapping a result
previews that stop's arrivals without changing the watched stop.
Next, from `docs/OMARCHY_PLUGIN.md`: settings/watchlist editing, alert
notifications. Out of scope: GPS nearby, route map, timetable.
