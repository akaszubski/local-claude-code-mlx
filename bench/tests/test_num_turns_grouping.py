"""Mixed num_turns within a (cond,case) cell must split into sub-rows."""
from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from _helpers import load_analyze


class TestNumTurnsGrouping(unittest.TestCase):
    def test_mixed_turns_emits_subrows(self) -> None:
        analyze = load_analyze()
        recs = []
        for i, nt in enumerate([3, 3, 5, 5, 3], 1):
            recs.append({
                "condition": "B",
                "case": "02_cc_list_files",
                "trial": i,
                "status": "ok",
                "wall_ms": 1000 + i * 100,
                "duration_ms": 1000 + i * 100,
                "num_turns": nt,
                "stdout_chars": 100,
                "log_offset_pre": 0,
                "log_offset_post": 0,
                "boot_offset": 0,
                "started_at": "2026-04-26T00:00:00Z",
            })
        rows = analyze.aggregate_cell(recs)
        # Two distinct num_turns values → two rows
        self.assertEqual(len(rows), 2)
        nts = sorted(r["num_turns"] for r in rows)
        self.assertEqual(nts, [3, 5])

    def test_summary_emits_two_lines(self) -> None:
        analyze = load_analyze()
        recs = []
        for i, nt in enumerate([3, 3, 5, 5, 3], 1):
            recs.append({
                "condition": "B",
                "case": "02_cc_list_files",
                "trial": i,
                "status": "ok",
                "wall_ms": 1000 + i * 100,
                "duration_ms": 1000 + i * 100,
                "num_turns": nt,
                "stdout_chars": 100,
                "log_offset_pre": 0,
                "log_offset_post": 0,
                "boot_offset": 0,
                "started_at": "2026-04-26T00:00:00Z",
            })
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            (run_dir / "raw.jsonl").write_text(
                "\n".join(json.dumps(r) for r in recs) + "\n"
            )
            (run_dir / "manifest.json").write_text(json.dumps({"run_id": "t"}))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(analyze.main(["--run-dir", str(run_dir)]), 0)
            text = (run_dir / "summary.md").read_text()
            # Count the table rows for 02_cc_list_files
            count = sum(
                1 for line in text.splitlines()
                if line.startswith("|") and "02_cc_list_files" in line
            )
            self.assertEqual(count, 2)


if __name__ == "__main__":
    unittest.main()
