"""Arrival-alert unit tests (stdlib only, no network)."""
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from stasi_client import oasa
from stasi_client.__main__ import main


def row(btime2, veh="v1", line="740", dest="D"):
    return {"route_code": "r", "veh_code": veh, "btime2": btime2,
            "line_code": line, "route_descr": dest}


class AlertsDueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.tmp.name})
        self.env.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)
        self.calls = 0

    def fake_post(self, act, params):
        self.calls += 1
        return [row("5", "v1"), row("6", "v2"), row(None, "v3"),
                {**row("3", None, "550", "E"), "veh_code": ""}]

    def due(self, **kwargs):
        kwargs.setdefault("force_refresh", True)
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            return oasa.alerts_due(["AAA"], 5, **kwargs)

    def test_boundary_and_unknown(self):
        result = self.due()
        self.assertEqual([(a["minutes"], a["veh_code"]) for a in result["notify"]],
                         [(3, ""), (5, "v1")])
        self.assertEqual(result["threshold"], 5)

    def test_no_repeat_once_notified(self):
        first = self.due()
        keys = first["notified"]
        self.assertIn("AAA#v1", keys)
        second = self.due(notified_keys=keys)
        self.assertEqual(second["notify"], [])
        self.assertEqual(second["notified"], keys)

    def test_fallback_key_without_vehicle(self):
        result = self.due()
        self.assertIn("AAA#550#E", result["notified"])

    def test_departed_bus_key_pruned(self):
        stale = ["AAA#v1", "AAA#gone"]
        result = self.due(notified_keys=stale)
        self.assertNotIn("AAA#gone", result["notified"])

    def test_disabled_threshold_fetches_nothing(self):
        with mock.patch.object(oasa, "_post", side_effect=self.fake_post):
            for threshold in (0, -2, "off"):
                result = oasa.alerts_due(["AAA"], threshold, force_refresh=True)
                self.assertEqual(result["notify"], [])
        self.assertEqual(self.calls, 0)

    def test_empty_codes_error(self):
        with self.assertRaises(ValueError):
            oasa.alerts_due([], 5)


class AlertsCliTest(unittest.TestCase):
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

    def test_cli_cycle(self):
        fake = lambda act, params: [row("4", "v9", "740", "D")]
        with mock.patch.object(oasa, "_post", side_effect=fake):
            code, first = self.run_cli(
                ["alerts", "--stop", "AAA", "--threshold", "5",
                 "--force-refresh"])
        self.assertEqual(code, 0)
        self.assertEqual(len(first["notify"]), 1)
        key = first["notified"][0]
        with mock.patch.object(oasa, "_post", side_effect=fake):
            code, second = self.run_cli(
                ["alerts", "--stop", "AAA", "--threshold", "5",
                 "--notified", key, "--force-refresh"])
        self.assertEqual(code, 0)
        self.assertEqual(second["notify"], [])

    def test_cli_blank_stop_is_json_error(self):
        code, payload = self.run_cli(
            ["alerts", "--stop", "  ", "--threshold", "5"])
        self.assertEqual(code, 1)
        self.assertIn("stop code", payload["error"])


if __name__ == "__main__":
    unittest.main()
