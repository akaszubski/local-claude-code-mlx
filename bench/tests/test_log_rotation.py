"""Log rotation (post < pre): ttft_ms=null + log_rotated=true; no crash."""
from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from _helpers import load_analyze


class TestLogRotation(unittest.TestCase):
    def test_post_less_than_pre_handled(self) -> None:
        analyze = load_analyze()
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            # The run.sh writes the rotation flag as log_rotated=True with
            # log_offset_pre=null and log_offset_post=null in the record.
            # analyze.py must not crash and must not assign a ttft.
            recs = [{
                "condition": "A",
                "case": "01_curl_hello",
                "trial": 1,
                "status": "ok",
                "wall_ms": 500,
                "duration_ms": 500,
                "num_turns": 1,
                "stdout_chars": 12,
                "log_offset_pre": None,
                "log_offset_post": None,
                "boot_offset": 0,
                "log_rotated": True,
                "started_at": "2026-04-26T00:00:00Z",
            }]
            (run_dir / "raw.jsonl").write_text(json.dumps(recs[0]) + "\n")
            (run_dir / "manifest.json").write_text(json.dumps({"run_id": "t"}))
            # Even with no log file, must complete cleanly.
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(analyze.main(["--run-dir", str(run_dir)]), 0)
            # Verify the backfilled record still has ttft_ms=None
            with (run_dir / "raw_with_ttft.jsonl").open() as f:
                line = f.readline()
            r = json.loads(line)
            self.assertIsNone(r.get("ttft_ms"))
            self.assertTrue(r.get("log_rotated"))


if __name__ == "__main__":
    unittest.main()
