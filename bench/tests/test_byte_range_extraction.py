"""B1: warmup log lines must NEVER be attributed to a real trial."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from _helpers import load_analyze


class TestByteRangeExtraction(unittest.TestCase):
    def test_warmup_lines_excluded_from_trial_range(self) -> None:
        analyze = load_analyze()
        # Build a fixture log:
        # - 3 warmup stream_outputs lines (id aaaa11112222)
        # - then 5 real-trial lines (different ids), each preceded by some
        #   filler so per-trial byte ranges bracket exactly one TTFT line.
        warmup_block = "".join(
            f"[stream_outputs] aaaa1111{n:04d} first token after 0.5s\n"
            for n in range(3)
        )
        # Each trial section: 100 bytes of filler + 1 ttft line
        trial_blocks = []
        trial_ttfts = [0.4, 0.6, 0.7, 0.8, 0.9]
        trial_ids = ["bbbb22220001", "cccc33330002", "dddd44440003",
                     "eeee55550004", "ffff66660005"]
        for tid, ttft in zip(trial_ids, trial_ttfts):
            filler = ("." * 200) + "\n"
            line = f"[stream_outputs] {tid} first token after {ttft}s\n"
            trial_blocks.append(filler + line)

        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "A.server.log"
            with log_path.open("wb") as f:
                f.write(warmup_block.encode())
                # Record offsets at the start and end of each trial block
                offsets: list[tuple[int, int]] = []
                for blk in trial_blocks:
                    pre = f.tell()
                    f.write(blk.encode())
                    post = f.tell()
                    offsets.append((pre, post))

            extracted_ttfts = []
            for pre, post in offsets:
                info = analyze.extract_ttft_from_log(log_path, pre, post)
                extracted_ttfts.append(info["ttft_ms"])

            # All 5 should be from the trial lines (0.4..0.9 s), not 0.5s warmup
            for got, want in zip(extracted_ttfts, trial_ttfts):
                self.assertIsNotNone(got, f"missing ttft, expected {want}")
                self.assertAlmostEqual(got, want * 1000.0, places=3)

            # Warmup-range extraction should NOT find a trial id, but if we
            # query the warmup byte range, we get the 0.5s warmup line. Confirm
            # that's well-behaved (returns 500.0, not crashes).
            warm_info = analyze.extract_ttft_from_log(
                log_path, 0, len(warmup_block.encode())
            )
            self.assertIsNotNone(warm_info["ttft_ms"])
            self.assertAlmostEqual(warm_info["ttft_ms"], 500.0)


if __name__ == "__main__":
    unittest.main()
