"""OSM raster tile fetch + disk cache (stdlib only).

Third-party apps may not hot-link tile.openstreetmap.org straight from a
bare network stack: OSM's tile usage policy
(operations.osmfoundation.org/policies/tiles) requires a descriptive
User-Agent identifying the application, and expects tiles to be cached
rather than re-fetched on every pan. QML's `Image { source: <tile url> }`
does neither -- it uses Qt's default, non-identifying User-Agent and never
caches -- which is what got this app blocked (HTTP 418, see osm.wiki/Blocked).
Route every tile through here instead: fetch once with a proper
identifying header, cache to disk, and have the shell load the cached
file (`Model.js`/`Panel.qml` never talk to tile.openstreetmap.org directly).
"""
import os
import time
import urllib.request

from stasi_client import oasa

TILE_BASE_URL = "https://tile.openstreetmap.org"
# Sequential per-process pacing between *uncached* tile fetches. OSM asks
# for "reasonable" request rates from non-bulk clients; this keeps a full
# cold-cache viewport (a dozen or so tiles) well under a couple of
# requests/second without making panning painfully slow.
TILE_RATE_LIMIT_SECONDS = 0.2
REQUEST_TIMEOUT_SECONDS = 10


def tile_cache_dir():
    path = os.path.join(oasa.cache_dir(), "tiles")
    os.makedirs(path, exist_ok=True)
    return path


def tile_cache_path(z, x, y):
    return os.path.join(tile_cache_dir(), str(int(z)), str(int(x)), "%d.png" % int(y))


def _throttle_tile_fetch():
    marker = os.path.join(oasa.cache_dir(), "last_tile_fetch.txt")
    now = time.time()
    try:
        with open(marker) as handle:
            last = float(handle.read().strip())
    except (OSError, ValueError):
        last = 0.0
    wait = TILE_RATE_LIMIT_SECONDS - (now - last)
    if wait > 0:
        time.sleep(wait)
        now = time.time()
    try:
        with open(marker, "w") as handle:
            handle.write(str(now))
    except OSError:
        pass


def fetch_tile(z, x, y, force_refresh=False):
    """Return the local cache path for one tile, downloading it if needed."""
    z, x, y = int(z), int(x), int(y)
    path = tile_cache_path(z, x, y)
    if not force_refresh and os.path.exists(path):
        return path
    _throttle_tile_fetch()
    request = urllib.request.Request(
        "%s/%d/%d/%d.png" % (TILE_BASE_URL, z, x, y),
        headers={"User-Agent": oasa.USER_AGENT, "Accept": "image/png"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        data = response.read()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)
    return path


def fetch_tiles(refs, force_refresh=False):
    """Fetch/cache a batch of (z, x, y) tiles; one failure skips, not fails, the rest."""
    results = []
    for z, x, y in refs:
        entry = {"z": z, "x": x, "y": y}
        try:
            entry["path"] = fetch_tile(z, x, y, force_refresh=force_refresh)
        except Exception as exc:
            entry["error"] = str(exc)
        results.append(entry)
    return results
