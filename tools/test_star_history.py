"""Offline regression checks for aggregate star data and safe banner generation."""

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError
from xml.etree import ElementTree as ET

import star_history as history


WEEK = 1783238400  # An API example epoch; never inferred from a UTC weekday.


def bucket(week=WEEK, days=None):
    days = days or [0] * 7
    return {"week": week, "total": sum(days), "days": days}


def snapshot(weeks=None):
    return {
        "schema_version": 1,
        "repository": "DVBeckwitt/Videre",
        "fetched_at": "2026-10-16",
        "source": history.source_url("DVBeckwitt/Videre"),
        "weeks": weeks if weeks is not None else [bucket(days=[0, 2, 0, 1, 0, 0, 0])],
    }


class Response(io.BytesIO):
    def __init__(self, value, link=""):
        super().__init__(json.dumps(value).encode())
        self.headers = {"Link": link}


class StarHistoryTests(unittest.TestCase):
    def test_sorts_and_accumulates_exact_daily_counts(self):
        # Deliberately use non-midnight boundaries and a DST-sized week shift.
        first = WEEK + 19800
        second = first + 7 * history.DAY - 3600
        value = snapshot([bucket(second, [0, 3, 0, 0, 0, 0, 0]),
                          bucket(first, [1, 0, 2, 0, 0, 0, 0])])
        points = history.cumulative_series(value)
        self.assertEqual(points[:-1], [(first, 0), (first, 1),
                                      (first + 2 * history.DAY, 3),
                                      (second + history.DAY, 6)])
        self.assertEqual(points[-1], (1792195199, 6))

    def test_fetches_multiple_pages_and_preserves_zero_weeks(self):
        weeks = [bucket(WEEK - i * 7 * history.DAY, [i % 3, 0, 0, 0, 0, 0, 0])
                 for i in range(32)]
        with patch.object(history, "urlopen", side_effect=[Response(weeks[:30]), Response(weeks[30:])]) as opener:
            result = history.fetch_history()
        self.assertEqual(result["weeks"], weeks)
        self.assertEqual(opener.call_count, 2)
        self.assertTrue(opener.call_args_list[1].args[0].full_url.endswith("per_page=30&page=2"))
        self.assertEqual(opener.call_args_list[0].kwargs["timeout"], 30)
        self.assertEqual(opener.call_args_list[0].args[0].get_header("X-github-api-version"), "2026-03-10")

    def test_full_final_page_requires_fetching_the_empty_next_page(self):
        weeks = [bucket(WEEK - i * 7 * history.DAY) for i in range(30)]
        with patch.object(history, "urlopen", side_effect=[Response(weeks), Response([])]) as opener:
            self.assertEqual(len(history.fetch_history()["weeks"]), 30)
        self.assertEqual(opener.call_count, 2)

    def test_refuses_partial_and_reordered_pagination(self):
        weeks = [bucket(WEEK - i * 7 * history.DAY) for i in range(30)]
        cases = [([Response(weeks)], 1),
                 ([Response(weeks), Response(weeks[:1])], 100),
                 ([Response(weeks[:1], '<page2>; rel="next"')], 100),
                 ([Response(list(reversed(weeks)))], 100)]
        for responses, limit in cases:
            with self.subTest(limit=limit, responses=len(responses)):
                with patch.object(history, "MAX_PAGES", limit), patch.object(history, "urlopen", side_effect=responses):
                    with self.assertRaises(ValueError):
                        history.fetch_history()

    def test_rejects_malformed_counts_and_missing_weeks(self):
        cases = [None, {}, [bucket(), bucket()],
                 [bucket(), bucket(WEEK + 14 * history.DAY)],
                 [{"week": WEEK, "total": 1, "days": [0] * 7}],
                 [{"week": True, "total": 0, "days": [0] * 7}],
                 [{"week": WEEK, "total": True, "days": [1, 0, 0, 0, 0, 0, 0]}],
                 [{"week": WEEK, "total": 0, "days": [0] * 6}],
                 [{"week": WEEK, "total": 0, "days": [False] * 7}],
                 [{"week": WEEK, "total": -1, "days": [-1, 0, 0, 0, 0, 0, 0]}]]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                history.validate_weeks(value)

    def test_rejects_invalid_snapshot_and_future_stars(self):
        for key, value in [("repository", 'owner/repo<script>'), ("schema_version", True),
                           ("source", "https://example.com"), ("fetched_at", "2026-99-99"),
                           ("weeks", [bucket(1792195200, [1, 0, 0, 0, 0, 0, 0])])]:
            changed = snapshot()
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                history.render_svg(changed)

    def test_zero_single_and_large_counts_render_safe_deterministic_xml(self):
        for count in (0, 1, 13, 1234567):
            value = snapshot([bucket(days=[count, 0, 0, 0, 0, 0, 0])])
            svg = history.render_svg(value)
            self.assertEqual(svg, history.render_svg(deepcopy(value)))
            root = ET.fromstring(svg)
            self.assertIn(f"{count:,} stars", root.find("{http://www.w3.org/2000/svg}title").text)
            self.assertNotIn("NaN", svg)
            self.assertNotIn("Infinity", svg)
            for element in root.iter():
                self.assertNotIn(element.tag.rsplit("}", 1)[-1], ("script", "image", "foreignObject"))
                self.assertFalse(any(key.startswith("on") or key.endswith("href") for key in element.attrib))
            paths = [element.attrib["d"] for element in root.iter("{http://www.w3.org/2000/svg}path")]
            self.assertTrue(any(" H " in path and " V " in path for path in paths))
            self.assertGreaterEqual(history.axis_ceiling(count), max(count, 1))
        self.assertEqual(history.cumulative_series(snapshot([]))[-1][1], 0)
        ET.fromstring(history.render_svg(snapshot([])))

    def test_network_and_validation_errors_preserve_both_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            svg, data = Path(directory) / "chart.svg", Path(directory) / "data.json"
            svg.write_text("existing SVG", encoding="utf-8")
            data.write_text("existing snapshot", encoding="utf-8")
            failures = [URLError("offline"), ValueError("incomplete response")]
            for error in failures:
                with patch.object(history, "fetch_history", side_effect=error), redirect_stderr(io.StringIO()):
                    self.assertEqual(history.main(["--output", str(svg), "--data-output", str(data)]), 1)
                self.assertEqual(svg.read_text(encoding="utf-8"), "existing SVG")
                self.assertEqual(data.read_text(encoding="utf-8"), "existing snapshot")
            malformed = snapshot()
            malformed["weeks"][0]["total"] = 999
            with patch.object(history, "fetch_history", return_value=malformed), redirect_stderr(io.StringIO()):
                self.assertEqual(history.main(["--output", str(svg), "--data-output", str(data)]), 1)
            self.assertEqual(svg.read_text(encoding="utf-8"), "existing SVG")
            self.assertEqual(data.read_text(encoding="utf-8"), "existing snapshot")

    def test_offline_cli_never_fetches_or_rewrites_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            data, svg = Path(directory) / "data.json", Path(directory) / "chart.svg"
            original = json.dumps(snapshot())
            data.write_text(original, encoding="utf-8")
            with patch.object(history, "urlopen", side_effect=AssertionError("offline must not fetch")), redirect_stdout(io.StringIO()):
                self.assertEqual(history.main(["--input", str(data), "--output", str(svg)]), 0)
            self.assertEqual(svg.read_text(encoding="utf-8"), history.render_svg(snapshot()))
            self.assertEqual(data.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
