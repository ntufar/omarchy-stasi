"""Watchlist (multi-stop arrivals) unit tests (stdlib only, no network)."""
import io
import json
import os
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import oasa
from stasi_client.__main__ import main


def arrival_row(btime2, line_code="740", route_descr="D"):
    return {"route_code": "r", "veh_code": "v", "btime2": btime2,
            "line_code": line_code, "route_descr": route_descr}


class MultiStopTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.tmp.name})
        self.env.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)

    def fake_post(self, act, params):
        rows = {
            "AAA": [arrival_row("5", "740"), arrival_row("1", "230")],
            "BBB": [arrival_row("3", "550"), arrival_row(None, "X")],
        }
        if act == "getStopArrivals" and params.get("p1") in rows:
            return rows[params["p1"]]
        raise urllib.error.URLError("stop unknown: %r" % (params,))

    def test_merged_sorted_unknowns_last(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            payload = oasa.get_stops_arrivals(["AAA", "BBB"], force_refresh=True)
        self.assertEqual([a["minutes"] for a in payload["arrivals"]], [1, 3, 5, None])
        self.assertEqual(payload["arrivals"][0]["stop"], "AAA")
        self.assertEqual(payload["arrivals"][0]["line"], "230")
        self.assertEqual(payload["arrivals"][0]["destination"], "D")
        self.assertEqual([s["stop"] for s in payload["stops"]], ["AAA", "BBB"])
        self.assertFalse(payload["cached"])

    def test_failing_stop_is_isolated(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            payload = oasa.get_stops_arrivals(["AAA", "CCC"], force_refresh=True)
        self.assertEqual(len(payload["stops"]), 2)
        self.assertIn("error", payload["stops"][1])
        self.assertEqual(payload["stops"][1]["stop"], "CCC")
        self.assertEqual(len(payload["arrivals"]), 2)

    def test_codes_deduped_and_stripped(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            payload = oasa.get_stops_arrivals([" AAA ", "AAA", "BBB"],
                                              force_refresh=True)
        self.assertEqual([s["stop"] for s in payload["stops"]], ["AAA", "BBB"])

    def test_empty_codes_rejected(self):
        with self.assertRaises(ValueError):
            oasa.get_stops_arrivals([])
        with self.assertRaises(ValueError):
            oasa.get_stops_arrivals(["  "])

    def test_second_call_served_from_cache(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            oasa.get_stops_arrivals(["AAA"], force_refresh=True)
            payload = oasa.get_stops_arrivals(["AAA"])
        self.assertTrue(payload["cached"])
        self.assertTrue(all(s["cached"] for s in payload["stops"]))

    def test_fetched_at_is_oldest_snapshot(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            payload = oasa.get_stops_arrivals(["AAA", "BBB"], force_refresh=True)
        stamps = [s["fetched_at"] for s in payload["stops"]]
        self.assertEqual(payload["fetched_at"], min(stamps))


class MultiStopCliTest(unittest.TestCase):
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

    def test_cli_multi_stop(self):
        rows = {"AAA": [arrival_row("5")], "BBB": [arrival_row("2")]}
        fake = lambda act, params: rows[params["p1"]]
        with mock.patch.object(oasa, "_post", side_effect=fake):
            code, payload = self.run_cli(
                ["arrivals", "--stop", "AAA", "--stop", "BBB",
                 "--force-refresh"])
        self.assertEqual(code, 0)
        self.assertEqual([s["stop"] for s in payload["stops"]], ["AAA", "BBB"])
        self.assertEqual([a["minutes"] for a in payload["arrivals"]], [2, 5])

    def test_cli_single_stop_shape(self):
        fake = lambda act, params: [arrival_row("4", "740", "SYN")]
        with mock.patch.object(oasa, "_post", side_effect=fake):
            code, payload = self.run_cli(
                ["arrivals", "--stop", "AAA", "--force-refresh"])
        self.assertEqual(code, 0)
        self.assertEqual(len(payload["stops"]), 1)
        self.assertEqual(payload["arrivals"][0]["line"], "740")
        self.assertIn("fetched_at", payload)


if __name__ == "__main__":
    unittest.main()
