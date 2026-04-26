"""Seed-from-capture rejects toy captures, accepts real-sized ones."""
from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from _helpers import load_capture_seed


class TestSeedValidation(unittest.TestCase):
    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.tmp = Path(self._td.name)

    def _run(self, capture_payload, *, expect_rc: int) -> Path:
        cs = load_capture_seed()
        in_path = self.tmp / "req.json"
        in_path.write_text(json.dumps(capture_payload))
        out_path = self.tmp / "seed.warm.json"
        args = mock.Mock(inp=str(in_path), out=str(out_path))
        buf_out, buf_err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            rc = cs.cmd_seed_from_capture(args)
        self.assertEqual(rc, expect_rc, f"unexpected rc={rc}; stderr={buf_err.getvalue()}")
        return out_path

    def test_rejects_toy_capture(self) -> None:
        # 10-token toy payload — well below 5000 bytes
        toy = {
            "system": "You are Claude.",
            "messages": [{"role": "user", "content": "hi"}],
        }
        self._run(toy, expect_rc=5)

    def test_accepts_realistic_capture(self) -> None:
        # ~10KB system + small user
        big_system = "You are Claude Code. " * 600  # ~12KB
        payload = {
            "system": big_system,
            "messages": [{"role": "user", "content": "list files"}],
        }
        out = self._run(payload, expect_rc=0)
        data = json.loads(out.read_text())
        self.assertIsInstance(data, list)
        self.assertEqual(len(data), 1)
        entry = data[0]
        self.assertEqual(entry[0]["role"], "system")
        self.assertGreater(len(entry[0]["content"]), 5000)
        self.assertEqual(entry[1]["role"], "user")

    def test_rejects_missing_system(self) -> None:
        payload = {
            "system": "",
            "messages": [{"role": "user", "content": "list files" * 1000}],
        }
        self._run(payload, expect_rc=3)

    def test_handles_anthropic_block_system(self) -> None:
        big = "You are Claude Code. " * 600
        payload = {
            "system": [
                {"type": "text", "text": big[:6000]},
                {"type": "text", "text": big[6000:]},
            ],
            "messages": [{"role": "user", "content": "list files"}],
        }
        out = self._run(payload, expect_rc=0)
        data = json.loads(out.read_text())
        self.assertGreater(len(data[0][0]["content"]), 5000)


if __name__ == "__main__":
    unittest.main()
