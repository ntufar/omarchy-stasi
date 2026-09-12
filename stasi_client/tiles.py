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
import colorsys
import os
import struct
import time
import urllib.request
import zlib

from stasi_client import oasa

TILE_BASE_URL = "https://tile.openstreetmap.org"
# "dark" reuses the same OSM source and inverts lightness locally (see
# _darken_tile) instead of pointing at a separate dark basemap provider:
# every free one we tried (CARTO's basemaps.cartocdn.com included) now
# stamps an "API KEY REQUIRED" watermark over anonymous raster requests.
TILE_STYLES = ("light", "dark")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
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


def tile_cache_path(z, x, y, style="light"):
    base = tile_cache_dir()
    # "light" keeps the original flat layout so existing caches stay valid;
    # "dark" gets its own subdir so the two never collide.
    if style == "dark":
        base = os.path.join(base, "dark")
    return os.path.join(base, str(int(z)), str(int(x)), "%d.png" % int(y))


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


def _read_png_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        raise ValueError("not a PNG")
    chunks = []
    pos = 8
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        cdata = data[pos + 8:pos + 8 + length]
        chunks.append([ctype, cdata])
        pos += 12 + length
        if ctype == b"IEND":
            break
    return chunks


def _write_png_chunks(chunks):
    out = [PNG_SIGNATURE]
    for ctype, cdata in chunks:
        out.append(struct.pack(">I", len(cdata)))
        out.append(ctype)
        out.append(cdata)
        out.append(struct.pack(">I", zlib.crc32(ctype + cdata) & 0xffffffff))
    return b"".join(out)


def _inverted_lightness(r, g, b):
    h, l, s = colorsys.rgb_to_hls(r / 255.0, g / 255.0, b / 255.0)
    nr, ng, nb = colorsys.hls_to_rgb(h, 1.0 - l, s)
    return round(nr * 255), round(ng * 255), round(nb * 255)


def darken_tile(data):
    """Recolor a light OSM raster tile for a dark theme.

    Inverting lightness in HSL space (keeping hue/saturation) turns the
    near-white background near-black and darkens roads/labels into light
    strokes on it, without a second tile provider or an image library:
    OSM's standard "mapnik" tiles are consistently 8-bit palette PNGs, so
    only the (<=256-entry) PLTE chunk needs touching, never the per-pixel
    data. A tile that isn't paletted (edge case some renderers can still
    produce) is returned unchanged -- a light tile beats a broken image.
    """
    try:
        chunks = _read_png_chunks(data)
    except (ValueError, struct.error):
        return data
    ihdr = next((cdata for ctype, cdata in chunks if ctype == b"IHDR"), None)
    if not ihdr or len(ihdr) < 10 or ihdr[9] != 3:  # color type 3 = palette
        return data
    out = []
    for ctype, cdata in chunks:
        if ctype == b"PLTE":
            entries = bytearray()
            for i in range(0, len(cdata) - 2, 3):
                nr, ng, nb = _inverted_lightness(cdata[i], cdata[i + 1], cdata[i + 2])
                entries += bytes((nr, ng, nb))
            cdata = bytes(entries)
        out.append([ctype, cdata])
    return _write_png_chunks(out)


def fetch_tile(z, x, y, style="light", force_refresh=False):
    """Return the local cache path for one tile, downloading it if needed."""
    z, x, y = int(z), int(x), int(y)
    path = tile_cache_path(z, x, y, style=style)
    if not force_refresh and os.path.exists(path):
        return path
    _throttle_tile_fetch()
    request = urllib.request.Request(
        "%s/%d/%d/%d.png" % (TILE_BASE_URL, z, x, y),
        headers={"User-Agent": oasa.USER_AGENT, "Accept": "image/png"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        data = response.read()
    if style == "dark":
        data = darken_tile(data)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)
    return path


def fetch_tiles(refs, style="light", force_refresh=False):
    """Fetch/cache a batch of (z, x, y) tiles; one failure skips, not fails, the rest."""
    results = []
    for z, x, y in refs:
        entry = {"z": z, "x": x, "y": y, "style": style}
        try:
            entry["path"] = fetch_tile(z, x, y, style=style, force_refresh=force_refresh)
        except Exception as exc:
            entry["error"] = str(exc)
        results.append(entry)
    return results
