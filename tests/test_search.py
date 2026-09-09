"""Stop-search unit tests (stdlib only, no network)."""
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import greek, oasa
from stasi_client.__main__ import main


def make_index(entries):
    return [{"stop_code": code, "descr": descr,
             "norm": greek.stop_search_norm(code, descr)}
            for code, descr in entries]


INDEX = make_index([
    ("060123", "ΣΥΝΤΑΓΜΑ"),
    ("060124", "ΠΛΑΤΕΙΑ ΣΥΝΤΑΓΜΑΤΟΣ"),
    ("040001", "ΑΓΙΟΣ ΔΗΜΗΤΡΙΟΣ"),
])


class GreeklishParityTest(unittest.TestCase):
    def test_syntagma_expands_exactly(self):
        self.assertEqual(greek.expand_latin_query("syntagma"), "συνταγμα")

    def test_expand_then_normalize_matches_greek(self):
        self.assertEqual(
            greek.normalize_greek(greek.expand_latin_query("syntagma")),
            greek.normalize_greek("ΣΥΝΤΑΓΜΑ"))


class ShapeCatalogTest(unittest.TestCase):
    def test_shape_lines(self):
        shaped = oasa.shape_lines([
            {"LineCode": "1151", "LineID": "021",
             "LineDescr": "ΠΛΑΤΕΙΑ ΚΑΝΙΓΓΟΣ - ΓΚΥΖH (ΚΥΚΛΙΚΗ)",
             "LineDescrEng": "PLATEIA KANIGKOS - GKIZI"},
            {"LineCode": "  ", "LineID": "x", "LineDescr": "blank"},
            "junk",
        ])
        self.assertEqual(len(shaped), 1)
        self.assertEqual(shaped[0]["line_code"], "1151")
        self.assertEqual(shaped[0]["line_id"], "021")

    def test_shape_routes(self):
        shaped = oasa.shape_routes([
            {"RouteCode": "2045", "LineCode": "1151",
             "RouteDescr": "ΠΕΙΡΑΙΑΣ-ΒΟΥΛΑ"},
            {"LineCode": "1151"},
            "junk",
        ])
        self.assertEqual(len(shaped), 1)
        self.assertEqual(shaped[0]["route_code"], "2045")

    def test_shape_catalog_stops(self):
        shaped = oasa.shape_catalog_stops([
            {"StopCode": "10183", "StopDescr": " ΠΕΙΡΑΙΑΣ ",
             "StopDescrEng": "PEIRAIAS",
             "StopLat": "37.938246", "StopLng": "23.6320605",
             "RouteStopOrder": "1", "StopType": "0", "StopAmea": "0"},
            {"StopCode": "", "StopDescr": "blank"},
            "junk",
        ])
        self.assertEqual(len(shaped), 1)
        self.assertEqual(shaped[0]["stop_code"], "10183")
        self.assertEqual(shaped[0]["descr"], "ΠΕΙΡΑΙΑΣ")


class SearchStopsTest(unittest.TestCase):
    def test_greeklish_finds_syntagma_first(self):
        hits = oasa.search_stops("syntagma", index=INDEX)
        self.assertGreaterEqual(len(hits), 2)
        self.assertEqual(hits[0]["stop_code"], "060123")
        self.assertEqual(hits[0]["descr"], "ΣΥΝΤΑΓΜΑ")

    def test_greek_query_same_result(self):
        hits = oasa.search_stops("ΣΥΝΤΑΓΜΑ", index=INDEX)
        self.assertEqual(hits[0]["stop_code"], "060123")

    def test_stop_code_prefix_ranks_first(self):
        hits = oasa.search_stops("0601", index=INDEX)
        self.assertEqual([h["stop_code"] for h in hits], ["060123", "060124"])

    def test_short_and_wildcard_queries_empty(self):
        self.assertEqual(oasa.search_stops("", index=INDEX), [])
        self.assertEqual(oasa.search_stops("a", index=INDEX), [])
        self.assertEqual(oasa.search_stops("%%", index=INDEX), [])

    def test_limit_is_respected(self):
        hits = oasa.search_stops("συνταγ", limit=1, index=INDEX)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["stop_code"], "060123")

    def test_result_shape(self):
        hits = oasa.search_stops("αγιος", index=INDEX)
        self.assertEqual(hits, [{"stop_code": "040001",
                                 "descr": "ΑΓΙΟΣ ΔΗΜΗΤΡΙΟΣ"}])


class BuildIndexTest(unittest.TestCase):
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
            self.assertEqual(params, {"p1": "1151"})
            return [{"RouteCode": "2045", "LineCode": "1151",
                     "RouteDescr": "R1"},
                    {"RouteCode": "2046", "LineCode": "1151",
                     "RouteDescr": "R2"}]
        if act == "webGetStops":
            if params == {"p1": "2045"}:
                return [{"StopCode": "10183", "StopDescr": " ΠΕΙΡΑΙΑΣ ",
                         "StopDescrEng": "PEIRAIAS"}]
            return [{"StopCode": "10183", "StopDescr": "ΠΕΙΡΑΙΑΣ"},
                    {"StopCode": "400191", "StopDescr": "ΚΛΕΙΣΟΒΗΣ"}]
        raise AssertionError("unexpected act %r" % act)

    def test_build_dedups_and_summarizes(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            summary = oasa.build_stop_index()
        self.assertEqual(summary["lines"], 1)
        self.assertEqual(summary["routes"], 2)
        self.assertEqual(summary["stops"], 2)
        stops = oasa.load_stop_index()
        self.assertEqual([s["stop_code"] for s in stops], ["10183", "400191"])
        self.assertEqual(stops[0]["norm"], "10183 πειραιας")

    def test_load_missing_index_is_none(self):
        self.assertIsNone(oasa.load_stop_index())


class SearchCliTest(unittest.TestCase):
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

    def test_search_without_index_is_json_error(self):
        code, payload = self.run_cli(["search", "syntagma"])
        self.assertEqual(code, 1)
        self.assertIn("refresh-stops", payload["error"])

    def test_search_with_index(self):
        oasa._write_json_cache(oasa.STOP_INDEX_FILENAME, INDEX)
        code, payload = self.run_cli(["search", "syntagma", "--limit", "5"])
        self.assertEqual(code, 0)
        self.assertEqual(payload["query"], "syntagma")
        self.assertEqual(payload["stops"][0]["stop_code"], "060123")


if __name__ == "__main__":
    unittest.main()
