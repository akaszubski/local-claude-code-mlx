"""Slowest-discard, IQR computation, and ⚠ high-variance marker."""
from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from _helpers import load_analyze


def _records(wall_ms_list, *, cond="A", case="01_curl_hello", num_turns=1):
    out = []
    for i, w in enumerate(wall_ms_list, 1):
        out.append({
            "condition": cond,
            "case": case,
            "trial": i,
            "status": "ok",
            "wall_ms": w,
            "duration_ms": w,
            "num_turns": num_turns,
            "stdout_chars": 10,
            "log_offset_pre": 0,
            "log_offset_post": 0,
            "boot_offset": 0,
            "started_at": "2026-04-26T00:00:00Z",
        })
    return out


class TestAggregation(unittest.TestCase):
    def test_slowest_discard_no_warning(self) -> None:
        analyze = load_analyze()
        recs = _records([100, 105, 110, 115, 9999])
        rows = analyze.aggregate_cell(recs)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        # first-call = trial 1 = 100
        self.assertEqual(row["first_call_wall_ms"], 100)
        # repeats = [105, 110, 115, 9999], slowest discarded → [105, 110, 115]
        self.assertAlmostEqual(row["repeat_call_median_wall_ms"], 110.0)
        # Should NOT be flagged
        self.assertFalse(row["high_variance"])

    def test_high_variance_flag(self) -> None:
        analyze = load_analyze()
        recs = _records([100, 200, 300, 400, 500])
        rows = analyze.aggregate_cell(recs)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        # first-call = 100; repeats = [200, 300, 400, 500] → drop slowest 500
        # remaining = [200, 300, 400], median 300, q1=250 q3=350 → IQR=100
        # IQR/median = 100/300 = 0.33 — NOT flagged. Need wider spread.
        self.assertAlmostEqual(row["repeat_call_median_wall_ms"], 300.0)

    def test_high_variance_flag_wide_spread(self) -> None:
        analyze = load_analyze()
        # Wider spread to force IQR/median > 0.5 after slowest-discard
        recs = _records([10, 100, 200, 300, 400])
        rows = analyze.aggregate_cell(recs)
        row = rows[0]
        # first=10; rest=[100,200,300,400] → drop 400 → [100,200,300]
        # median 200, q1=125 q3=275 → IQR=150 → 150/200 = 0.75 → flagged
        self.assertAlmostEqual(row["repeat_call_median_wall_ms"], 200.0)
        self.assertTrue(row["high_variance"])

    def test_summary_renders_warn_marker(self) -> None:
        analyze = load_analyze()
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            recs = _records([10, 100, 200, 300, 400])
            (run_dir / "raw.jsonl").write_text(
                "\n".join(json.dumps(r) for r in recs) + "\n"
            )
            (run_dir / "manifest.json").write_text(json.dumps({"run_id": "t"}))
            # No server log → no ttft backfill
            with contextlib.redirect_stdout(io.StringIO()):
                rc = analyze.main(["--run-dir", str(run_dir)])
            self.assertEqual(rc, 0)
            text = (run_dir / "summary.md").read_text()
            self.assertIn("⚠", text)


if __name__ == "__main__":
    unittest.main()
