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
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import oasa, tiles
from stasi_client.__main__ import main


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
        fetch.assert_called_once_with([(13, 1, 1)], force_refresh=False)
        self.assertEqual(code, 0)
        self.assertEqual(payload["tiles"][0]["path"], "/tmp/x.png")

    def test_map_tiles_cli_rejects_bad_ref(self):
        code, payload = self.run_cli(["map-tiles", "--tile", "not-a-tile"])
        self.assertEqual(code, 1)
        self.assertIn("bad tile ref", payload["error"])


if __name__ == "__main__":
    unittest.main()
