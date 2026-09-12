"""OSM tile fetch/cache unit tests (stdlib only, no real network).

Regression coverage for the 418 "Access blocked ... not following the tile
usage policy" (osm.wiki/Blocked) response tile.openstreetmap.org sends a
client with no identifying User-Agent: every fetch here must carry
`oasa.USER_AGENT` and land on disk so a repeat view never re-hits the
network for the same tile.
"""
import io
import json
import os
import struct
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import oasa, tiles
from stasi_client.__main__ import main


def _png_chunk(ctype, data):
    return (struct.pack(">I", len(data)) + ctype + data
            + struct.pack(">I", zlib.crc32(ctype + data) & 0xffffffff))


def _make_palette_png(width, height, palette, pixels):
    """Build a minimal 8-bit paletted PNG, the shape every real OSM
    "mapnik" raster tile takes, for darken_tile tests with no image
    library (and no real tile) involved."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type "None" for this scanline
        raw += pixels[y * width:(y + 1) * width]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    plte = b"".join(bytes(c) for c in palette)
    return (tiles.PNG_SIGNATURE + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"PLTE", plte) + _png_chunk(b"IDAT", zlib.compress(bytes(raw)))
            + _png_chunk(b"IEND", b""))


def _read_palette(png_bytes):
    for ctype, cdata in tiles._read_png_chunks(png_bytes):
        if ctype == b"PLTE":
            return [tuple(cdata[i:i + 3]) for i in range(0, len(cdata), 3)]
    return None


class _FakeResponse:
    def __init__(self, data):
        self._data = data

    def read(self):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FetchTileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.tmp.name})
        self.env.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)
        self.throttle = mock.patch.object(tiles, "_throttle_tile_fetch")
        self.throttle.start()
        self.addCleanup(self.throttle.stop)

    def test_downloads_with_identifying_user_agent(self):
        captured = {}

        def fake_urlopen(request, timeout=None):
            captured["url"] = request.full_url
            captured["headers"] = request.headers
            return _FakeResponse(b"png-bytes")

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            path = tiles.fetch_tile(13, 4661, 3086)

        self.assertEqual(captured["url"],
                          "https://tile.openstreetmap.org/13/4661/3086.png")
        # urllib title-cases header names ("User-agent"); the value is what
        # OSM's policy actually checks.
        self.assertEqual(captured["headers"]["User-agent"], oasa.USER_AGENT)
        self.assertTrue(os.path.exists(path))
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), b"png-bytes")

    def test_cached_tile_skips_network(self):
        with mock.patch("urllib.request.urlopen",
                        return_value=_FakeResponse(b"a")) as urlopen:
            tiles.fetch_tile(13, 1, 1)
        with mock.patch("urllib.request.urlopen") as urlopen2:
            path = tiles.fetch_tile(13, 1, 1)
        urlopen2.assert_not_called()
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), b"a")

    def test_force_refresh_redownloads(self):
        with mock.patch("urllib.request.urlopen",
                        return_value=_FakeResponse(b"old")):
            tiles.fetch_tile(13, 2, 2)
        with mock.patch("urllib.request.urlopen",
                        return_value=_FakeResponse(b"new")) as urlopen:
            path = tiles.fetch_tile(13, 2, 2, force_refresh=True)
        urlopen.assert_called_once()
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), b"new")

    def test_dark_style_hits_same_osm_url_and_caches_separately_from_light(self):
        # "dark" must never point at a different tile provider: every free
        # dark basemap we tried now demands an API key for anonymous raster
        # requests and stamps a watermark over the tile instead of serving
        # it (basemaps.cartocdn.com included) -- see darken_tile.
        light_png = _make_palette_png(1, 1, [(255, 255, 255)], bytes([0]))
        urls = []

        def fake_urlopen(request, timeout=None):
            urls.append(request.full_url)
            return _FakeResponse(light_png)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            light_path = tiles.fetch_tile(13, 4661, 3086, style="light")
            dark_path = tiles.fetch_tile(13, 4661, 3086, style="dark")

        self.assertEqual(urls, [
            "https://tile.openstreetmap.org/13/4661/3086.png",
            "https://tile.openstreetmap.org/13/4661/3086.png",
        ])
        self.assertNotEqual(light_path, dark_path)
        with open(light_path, "rb") as handle:
            self.assertEqual(_read_palette(handle.read()), [(255, 255, 255)])
        with open(dark_path, "rb") as handle:
            self.assertEqual(_read_palette(handle.read()), [(0, 0, 0)])


class DarkenTileTest(unittest.TestCase):
    def test_inverts_palette_lightness_keeps_pixel_data(self):
        # index0 = white background, index1 = near-black road line.
        pixels = bytes([0, 0, 1, 0])  # 2x2, one pixel is the "road"
        png = _make_palette_png(2, 2, [(255, 255, 255), (20, 20, 20)], pixels)

        darkened = tiles.darken_tile(png)

        self.assertEqual(_read_palette(darkened), [(0, 0, 0), (235, 235, 235)])
        # Same pixel layout -- only which color each index maps to changed.
        chunks = dict(tiles._read_png_chunks(darkened))
        self.assertEqual(dict(tiles._read_png_chunks(png))[b"IDAT"], chunks[b"IDAT"])

    def test_keeps_hue_for_colored_features(self):
        # A park's saturated green should darken, not turn grey or invert hue.
        green_park = (150, 200, 130)
        png = _make_palette_png(1, 1, [green_park], bytes([0]))

        r, g, b = _read_palette(tiles.darken_tile(png))[0]

        self.assertLess(g, green_park[1])  # darkened
        self.assertGreater(g, r)  # still visibly green, not grey/inverted hue
        self.assertGreater(g, b)

    def test_non_palette_png_returned_unchanged(self):
        ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)  # color type 2 = truecolor
        png = (tiles.PNG_SIGNATURE + _png_chunk(b"IHDR", ihdr)
               + _png_chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff"))
               + _png_chunk(b"IEND", b""))

        self.assertEqual(tiles.darken_tile(png), png)

    def test_garbage_input_returned_unchanged(self):
        self.assertEqual(tiles.darken_tile(b"not a png"), b"not a png")

    def test_fetch_tiles_isolates_one_failure(self):
        def fake_urlopen(request, timeout=None):
            if "9/9/9" in request.full_url:
                raise OSError("blocked")
            return _FakeResponse(b"ok")

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            results = tiles.fetch_tiles([(13, 3, 3), (9, 9, 9)])

        self.assertIn("path", results[0])
        self.assertIn("error", results[1])
        self.assertNotIn("path", results[1])


class MapTilesCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.tmp.name})
        self.env.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)

    def run_cli(self, argv):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = main(argv)
        return code, json.loads(buffer.getvalue())

    def test_map_tiles_cli_shapes_batch(self):
        with mock.patch.object(tiles, "fetch_tiles",
                               return_value=[{"z": 13, "x": 1, "y": 1,
                                              "path": "/tmp/x.png"}]) as fetch:
            code, payload = self.run_cli(["map-tiles", "--tile", "13/1/1"])
        fetch.assert_called_once_with([(13, 1, 1)], style="light", force_refresh=False)
        self.assertEqual(code, 0)
        self.assertEqual(payload["tiles"][0]["path"], "/tmp/x.png")

    def test_map_tiles_cli_passes_style(self):
        with mock.patch.object(tiles, "fetch_tiles",
                               return_value=[{"z": 13, "x": 1, "y": 1,
                                              "style": "dark",
                                              "path": "/tmp/x.png"}]) as fetch:
            code, payload = self.run_cli(
                ["map-tiles", "--tile", "13/1/1", "--style", "dark"])
        fetch.assert_called_once_with([(13, 1, 1)], style="dark", force_refresh=False)
        self.assertEqual(code, 0)

    def test_map_tiles_cli_rejects_bad_ref(self):
        code, payload = self.run_cli(["map-tiles", "--tile", "not-a-tile"])
        self.assertEqual(code, 1)
        self.assertIn("bad tile ref", payload["error"])


if __name__ == "__main__":
    unittest.main()
