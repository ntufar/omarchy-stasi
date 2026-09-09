"""Helper unit tests (stdlib only, no network). Run: python3 -m unittest discover -s tests."""
import unittest

from stasi_client import greek
from stasi_client.oasa import parse_btime2, shape_arrivals


class GreekTest(unittest.TestCase):
    def test_normalize_strips_accents(self):
        self.assertEqual(greek.normalize_greek("ΣΥΝΤΑΓΜΑ"), "συνταγμα")

    def test_greeklish_expansion(self):
        expanded = greek.expand_latin_query("syntagma")
        self.assertIn("σ", expanded)
        self.assertTrue(
            greek.normalize_greek("ΣΥΝΤΑΓΜΑ") in greek.normalize_greek(expanded)
            or expanded.startswith("σ"))

    def test_short_and_mixed_queries_unchanged(self):
        self.assertEqual(greek.expand_latin_query("a"), "a")
        self.assertEqual(greek.expand_latin_query("224"), "224")


class ArrivalsTest(unittest.TestCase):
    def test_btime_digits(self):
        self.assertEqual(parse_btime2("4"), 4)
        self.assertEqual(parse_btime2(" 12' "), 12)

    def test_btime_unknown(self):
        self.assertIsNone(parse_btime2(None))
        self.assertIsNone(parse_btime2(""))
        self.assertIsNone(parse_btime2("—"))

    def test_shape_arrivals(self):
        shaped = shape_arrivals([
            {"route_code": "123", "veh_code": "v1", "btime2": "4",
             "line_code": "740", "route_descr": "ΣΚΑΡΑΜΑΓΚΑΣ - ΣΤ. ΚΟΡΩΠΙΟΥ"},
            {"btime2": None},
            "junk",
        ])
        self.assertEqual(len(shaped), 2)
        self.assertEqual(shaped[0]["minutes"], 4)
        self.assertEqual(shaped[0]["line_code"], "740")
        self.assertIsNone(shaped[1]["minutes"])


if __name__ == "__main__":
    unittest.main()
