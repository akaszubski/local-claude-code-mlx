#!/usr/bin/env python3
"""Aggregate raw.jsonl + per-condition server logs into summary.md."""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path
from typing import Any

TTFT_PATTERN = re.compile(
    r"\[stream_outputs\] [0-9a-f]{12} first token after ([0-9.]+)s"
)


def extract_ttft_from_log(log_path: Path, pre: int, post: int) -> dict[str, Any]:
    """Read bytes [pre, post) from log_path, return first TTFT match (ms).

    Returns dict with keys: ttft_ms, ttft_missing_reason, multiple_ttft_lines.
    """
    out: dict[str, Any] = {
        "ttft_ms": None,
        "ttft_missing_reason": None,
        "multiple_ttft_lines": False,
    }
    if not log_path.exists():
        out["ttft_missing_reason"] = "log_missing"
        return out
    if pre is None or post is None or post <= pre:
        out["ttft_missing_reason"] = "empty_or_invalid_range"
        return out
    try:
        with log_path.open("rb") as f:
            f.seek(pre)
            chunk = f.read(post - pre)
    except OSError as e:
        out["ttft_missing_reason"] = f"read_error: {e}"
        return out
    text = chunk.decode("utf-8", errors="replace")
    matches = TTFT_PATTERN.findall(text)
    if not matches:
        out["ttft_missing_reason"] = "no_line_in_range"
        return out
    if len(matches) > 1:
        out["multiple_ttft_lines"] = True
    out["ttft_ms"] = float(matches[0]) * 1000.0
    return out


def _median(xs: list[float]) -> float | None:
    if not xs:
        return None
    return float(statistics.median(xs))


def _iqr(xs: list[float]) -> float | None:
    if len(xs) < 2:
        return None
    qs = statistics.quantiles(xs, n=4)
    return float(qs[2] - qs[0])  # q3 - q1


def _drop_slowest(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return list with the single slowest-by-wall_ms record removed."""
    if not records:
        return records
    keyed = [(r.get("wall_ms") if r.get("wall_ms") is not None else -1, i, r)
             for i, r in enumerate(records)]
    slowest_idx = max(keyed, key=lambda t: t[0])[1]
    return [r for i, r in enumerate(records) if i != slowest_idx]


def aggregate_cell(
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Aggregate per-(cond,case) trial records into one or more summary rows.

    Splits into sub-rows when num_turns differs across kept (ok) records.
    """
    ok_records = [r for r in records if r.get("status") == "ok"]
    if not ok_records:
        return [{
            "first_call_wall_ms": None,
            "first_call_ttft_ms": None,
            "repeat_call_median_wall_ms": None,
            "repeat_call_iqr_wall_ms": None,
            "repeat_call_median_ttft_ms": None,
            "repeat_call_iqr_ttft_ms": None,
            "num_turns": None,
            "n_trials": 0,
            "high_variance": False,
        }]

    # Group by num_turns
    groups: dict[Any, list[dict[str, Any]]] = {}
    for r in ok_records:
        groups.setdefault(r.get("num_turns"), []).append(r)

    rows: list[dict[str, Any]] = []
    for nt, recs in groups.items():
        recs_sorted = sorted(recs, key=lambda r: r.get("trial", 0))
        first = recs_sorted[0] if recs_sorted else None
        rest = recs_sorted[1:] if len(recs_sorted) > 1 else []
        kept = _drop_slowest(rest) if len(rest) >= 2 else rest

        wall_vals = [float(r["wall_ms"]) for r in kept if r.get("wall_ms") is not None]
        ttft_vals = [float(r["ttft_ms"]) for r in kept if r.get("ttft_ms") is not None]

        median_wall = _median(wall_vals)
        iqr_wall = _iqr(wall_vals)
        median_ttft = _median(ttft_vals)
        iqr_ttft = _iqr(ttft_vals)

        high_var = False
        if median_wall and iqr_wall and median_wall > 0:
            high_var = (iqr_wall / median_wall) > 0.5

        rows.append({
            "first_call_wall_ms": first.get("wall_ms") if first else None,
            "first_call_ttft_ms": first.get("ttft_ms") if first else None,
            "repeat_call_median_wall_ms": median_wall,
            "repeat_call_iqr_wall_ms": iqr_wall,
            "repeat_call_median_ttft_ms": median_ttft,
            "repeat_call_iqr_ttft_ms": iqr_ttft,
            "num_turns": nt,
            "n_trials": len(recs_sorted),
            "n_repeat_kept": len(kept),
            "high_variance": high_var,
        })
    return rows


def _fmt_int(x: Any) -> str:
    return "—" if x is None else f"{int(round(float(x)))}"


def _fmt_pair(median: Any, iqr: Any) -> str:
    if median is None:
        return "—"
    if iqr is None:
        return f"{int(round(float(median)))} (IQR —)"
    return f"{int(round(float(median)))} (IQR {int(round(float(iqr)))})"


def render_summary(run_dir: Path, manifest: dict[str, Any], rows_by_key: dict, ttft_audit: dict) -> str:
    lines: list[str] = []
    lines.append(f"# Bench run {manifest.get('run_id', run_dir.name)}")
    lines.append("")
    lines.append("## How to read this report")
    lines.append("")
    lines.append(
        "This run measures Claude Code request latency under four cache configurations"
    )
    lines.append(
        "(A: baseline, B: warm-prompts, C: +ssd-cache, D: +int8 KV) across five cases."
    )
    lines.append("")
    lines.append(
        "The \"first-call\" column is the very first request after the server is healthy"
    )
    lines.append(
        "— for conditions B/C/D the prefix cache has already been seeded by --warm-prompts,"
    )
    lines.append(
        "so \"B first-call\" is faster than \"A first-call\" by exactly the warmup benefit."
    )
    lines.append(
        "The \"repeat-call\" column is the median of trials 2..N (with slowest discarded)"
    )
    lines.append(
        "and reflects steady-state cache behavior. Variance is reported as IQR; cells"
    )
    lines.append(
        "flagged ⚠ have IQR/median > 0.5, meaning the signal is noisy and the comparison"
    )
    lines.append("is not reliable on this run.")
    lines.append("")
    lines.append("## Results")
    lines.append("")
    lines.append(
        "| Cond | Case | first-call wall_ms | first-call ttft_ms | "
        "repeat wall_ms (med, IQR) | repeat ttft_ms (med, IQR) | turns |"
    )
    lines.append(
        "|------|------|-------------------:|-------------------:|"
        "--------------------------:|--------------------------:|------:|"
    )

    for (cond, case_id), rows in sorted(rows_by_key.items()):
        # Skip the post-restart pseudo case from the main table
        if case_id == "05_post_restart":
            continue
        for row in rows:
            warn = " ⚠ high-variance" if row.get("high_variance") else ""
            lines.append(
                "| {cond} | {case} | {fcw} | {fct} | {rwm}{w} | {rtm} | {nt} |".format(
                    cond=cond,
                    case=case_id,
                    fcw=_fmt_int(row["first_call_wall_ms"]),
                    fct=_fmt_int(row["first_call_ttft_ms"]),
                    rwm=_fmt_pair(row["repeat_call_median_wall_ms"], row["repeat_call_iqr_wall_ms"]),
                    rtm=_fmt_pair(row["repeat_call_median_ttft_ms"], row["repeat_call_iqr_ttft_ms"]),
                    nt=("—" if row.get("num_turns") is None else row["num_turns"]),
                    w=warn,
                )
            )

    lines.append("")
    lines.append("## Post-restart pass (case 5)")
    lines.append("")
    pr_rows = [
        (cond, rows) for (cond, case_id), rows in sorted(rows_by_key.items())
        if case_id == "05_post_restart"
    ]
    if not pr_rows:
        lines.append("_(no case 5 records)_")
    else:
        lines.append("| Cond | wall_ms | ttft_ms | turns |")
        lines.append("|------|--------:|--------:|------:|")
        for cond, rows in pr_rows:
            for row in rows:
                lines.append(
                    f"| {cond} | {_fmt_int(row['first_call_wall_ms'])} | "
                    f"{_fmt_int(row['first_call_ttft_ms'])} | "
                    f"{'—' if row.get('num_turns') is None else row['num_turns']} |"
                )
    lines.append("")

    lines.append("## Errors")
    lines.append("")
    err_records = []
    for line in (run_dir / "raw.jsonl").read_text().splitlines():
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("status") and r["status"] != "ok":
            err_records.append(r)
    if not err_records:
        lines.append("_(no errors)_")
    else:
        lines.append("| Cond | Case | Trial | Status | Error class | Message |")
        lines.append("|------|------|------:|--------|-------------|---------|")
        for r in err_records:
            msg = (r.get("error_message") or "")[:100].replace("|", "\\|").replace("\n", " ")
            lines.append(
                f"| {r.get('condition','?')} | {r.get('case','?')} | "
                f"{r.get('trial','?')} | {r.get('status','?')} | "
                f"{r.get('error_class','—')} | {msg} |"
            )
    lines.append("")

    lines.append("## TTFT backfill audit")
    lines.append("")
    lines.append("| Condition | cc records | ttft lines found |")
    lines.append("|-----------|-----------:|-----------------:|")
    for cond, stats in sorted(ttft_audit.items()):
        lines.append(f"| {cond} | {stats['cc_records']} | {stats['ttft_found']} |")
    lines.append("")

    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--run-dir", required=True)
    args = p.parse_args(argv)

    run_dir = Path(args.run_dir).resolve()
    raw_path = run_dir / "raw.jsonl"
    if not raw_path.exists():
        print(f"raw.jsonl not found at {raw_path}", file=sys.stderr)
        return 2

    manifest_path = run_dir / "manifest.json"
    manifest: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text())
        except Exception:
            manifest = {}

    records: list[dict[str, Any]] = []
    for line in raw_path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue

    # Backfill ttft_ms for ok records that have offsets and a server log.
    ttft_audit: dict[str, dict[str, int]] = {}
    for r in records:
        cond = r.get("condition")
        if not cond:
            continue
        ttft_audit.setdefault(cond, {"cc_records": 0, "ttft_found": 0})
        if r.get("status") != "ok":
            continue
        # Only cc-style cases produce per-request stream_outputs lines reliably,
        # but curl /v1/messages also flows through stream_outputs, so try all.
        ttft_audit[cond]["cc_records"] += 1
        pre = r.get("log_offset_pre")
        post = r.get("log_offset_post")
        if pre is None or post is None:
            continue
        log_path = run_dir / f"{cond}.server.log"
        info = extract_ttft_from_log(log_path, pre, post)
        if info["ttft_ms"] is not None:
            r["ttft_ms"] = info["ttft_ms"]
            ttft_audit[cond]["ttft_found"] += 1
        else:
            r["ttft_ms"] = None
            r["ttft_missing_reason"] = info["ttft_missing_reason"]
        if info["multiple_ttft_lines"]:
            r["multiple_ttft_lines"] = True

    # Group by (condition, case)
    by_key: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for r in records:
        key = (r.get("condition", "?"), r.get("case", "?"))
        by_key.setdefault(key, []).append(r)

    rows_by_key = {k: aggregate_cell(v) for k, v in by_key.items()}

    summary = render_summary(run_dir, manifest, rows_by_key, ttft_audit)
    (run_dir / "summary.md").write_text(summary)

    # Also emit a backfilled raw.jsonl alongside (so users can see ttft).
    backfilled = run_dir / "raw_with_ttft.jsonl"
    with backfilled.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    print(f"summary.md written to {run_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
