"""Map data unit tests (stdlib only, no network)."""
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import greek, oasa
from stasi_client.__main__ import main


LINES = [
    {"line_code": "1151", "line_id": "021", "line_descr": "PLATEIA KANIGKOS - GKIZI"},
    {"line_code": "1152", "line_id": "224", "line_descr": "POLYGONO - ELLINIKO"},
    {"line_code": "1153", "line_id": "608", "line_descr": "ΓΑΛΑΤΣΙ - ΑΚΑΔΗΜΙΑ"},
]


class ShapeCoordsTest(unittest.TestCase):
    def test_lat_lng_parsed(self):
        shaped = oasa.shape_catalog_stops([
            {"StopCode": "10183", "StopDescr": " PIREAS ",
             "StopLat": "37.938246", "StopLng": "23.6320605"},
            {"StopCode": "400191", "StopDescr": "X",
             "StopLat": "bad", "StopLng": ""},
            {"StopCode": "", "StopDescr": "blank"},
        ])
        self.assertEqual(len(shaped), 2)
        self.assertAlmostEqual(shaped[0]["lat"], 37.938246)
        self.assertAlmostEqual(shaped[0]["lng"], 23.6320605)
        self.assertIsNone(shaped[1]["lat"])
        self.assertIsNone(shaped[1]["lng"])

    def test_line_search_norm(self):
        self.assertEqual(greek.line_search_norm("021", "1151", "Gkizi"),
                         "021 1151 gkizi")


class SearchLinesTest(unittest.TestCase):
    def test_line_number_prefix_first(self):
        hits = oasa.search_lines("224", lines=LINES)
        self.assertEqual(hits[0]["line_id"], "224")

    def test_greeklish_name_substring(self):
        hits = oasa.search_lines("galatsi", lines=LINES)
        self.assertEqual([h["line_id"] for h in hits], ["608"])

    def test_greek_name_substring(self):
        hits = oasa.search_lines("ακαδη", lines=LINES)
        self.assertEqual([h["line_id"] for h in hits], ["608"])

    def test_short_query_empty(self):
        self.assertEqual(oasa.search_lines("2", lines=LINES), [])

    def test_limit(self):
        hits = oasa.search_lines("11", limit=1, lines=LINES)
        self.assertEqual(len(hits), 1)


class MapDataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.tmp.name})
        self.env.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)

    def fake_post(self, act, params):
        if act == "webGetLines":
            return [{"LineCode": "1151", "LineID": "021", "LineDescr": "L1"}]
        if act == "webGetRoutes":
            return [{"RouteCode": "2045", "LineCode": "1151", "RouteDescr": "R1"}]
        if act == "webGetStops":
            return [{"StopCode": "10183", "StopDescr": "PIREAS",
                     "StopLat": "37.9", "StopLng": "23.6"},
                    {"StopCode": "400191", "StopDescr": "NOCOORDS"}]
        raise AssertionError("unexpected %r %r" % (act, params))

    def test_index_carries_coords(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            summary = oasa.build_stop_index()
        self.assertEqual(summary["stops"], 2)
        stops = oasa.load_stop_index()
        self.assertAlmostEqual(stops[0]["lat"], 37.9)
        self.assertIsNone(stops[1].get("lat"))

    def test_line_stops_shape(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            payload = oasa.line_stops("1151")
        self.assertEqual(payload["line_code"], "1151")
        self.assertEqual(len(payload["routes"]), 1)
        route = payload["routes"][0]
        self.assertEqual(route["route_code"], "2045")
        self.assertAlmostEqual(route["stops"][0]["lng"], 23.6)

    def test_line_stops_blank_rejected(self):
        with self.assertRaises(ValueError):
            oasa.line_stops("  ")

    def test_stops_geo_filters_and_guards(self):
        self.assertRaises(RuntimeError, oasa.stops_geo)
        oasa._write_json_cache(oasa.STOP_INDEX_FILENAME, [
            {"stop_code": "A", "descr": "Has", "norm": "a has",
             "lat": 37.9, "lng": 23.6},
            {"stop_code": "B", "descr": "Missing", "norm": "b missing",
             "lat": None, "lng": None},
        ])
        geo = oasa.stops_geo()
        self.assertEqual([s["stop_code"] for s in geo], ["A"])


class MapCliTest(unittest.TestCase):
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

    def test_search_lines_cli(self):
        oasa._write_json_cache("lines.json", LINES)
        code, payload = self.run_cli(["search-lines", "224"])
        self.assertEqual(code, 0)
        self.assertEqual(payload["lines"][0]["line_id"], "224")

    def test_line_stops_cli(self):
        def fake(act, params):
            if act == "webGetRoutes":
                return [{"RouteCode": "1", "LineCode": "L", "RouteDescr": "R"}]
            return [{"StopCode": "S", "StopDescr": "D",
                     "StopLat": "1.5", "StopLng": "2.5"}]
        with mock.patch.object(oasa, "_post", side_effect=fake):
            code, payload = self.run_cli(["line-stops", "--line", "L"])
        self.assertEqual(code, 0)
        self.assertEqual(payload["routes"][0]["stops"][0]["lat"], 1.5)

    def test_stops_geo_cli_missing_index(self):
        code, payload = self.run_cli(["stops-geo"])
        self.assertEqual(code, 1)
        self.assertIn("refresh-stops", payload["error"])


if __name__ == "__main__":
    unittest.main()
