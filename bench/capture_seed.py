#!/usr/bin/env python3
"""Step 0 helper: capture a real Claude Code request, then convert to seed.warm.json."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

CAPTURE_SERVER = Path.home() / "Dev/local-claude-code-mlx/vllm-mlx/scripts/capture_server.py"

MIN_TOTAL_BYTES = 5000


def _system_to_text(system: Any) -> str:
    """Anthropic 'system' is either a str or a list of {type:'text', text:'...'} blocks."""
    if system is None:
        return ""
    if isinstance(system, str):
        return system
    if isinstance(system, list):
        out: list[str] = []
        for block in system:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and isinstance(block.get("text"), str):
                out.append(block["text"])
        return "".join(out)
    return ""


def _validate_warmup_shape(data: Any, *, source: str) -> None:
    """Re-implements vllm_mlx.prompt_warmup.load_warmup_file rules inline."""
    if not isinstance(data, list):
        raise ValueError(
            f"{source}: top-level must be a JSON list, got {type(data).__name__}"
        )
    if not data:
        raise ValueError(f"{source}: warm-up file is empty")
    for i, entry in enumerate(data):
        if not isinstance(entry, list) or not entry:
            raise ValueError(
                f"{source}: entry {i} must be a non-empty list of message dicts"
            )
        for j, msg in enumerate(entry):
            if not isinstance(msg, dict):
                raise ValueError(
                    f"{source}: entry {i} message {j} must be a dict, "
                    f"got {type(msg).__name__}"
                )
            if "role" not in msg or "content" not in msg:
                raise ValueError(
                    f"{source}: entry {i} message {j} missing 'role' or 'content'"
                )


def cmd_capture_start(args: argparse.Namespace) -> int:
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not CAPTURE_SERVER.exists():
        print(f"capture_server.py not found at {CAPTURE_SERVER}", file=sys.stderr)
        return 1
    print(f"Starting capture proxy on http://127.0.0.1:{args.port}")
    print(f"  Captured request will be written to: {out_path}")
    print()
    print("In a SECOND terminal, run a realistic Claude Code request, e.g.:")
    print(f"  ANTHROPIC_BASE_URL=http://127.0.0.1:{args.port} \\")
    print("  ANTHROPIC_API_KEY=not-needed \\")
    print("  claude --print 'list the files in this directory'")
    print()
    print("Send Ctrl-C to this proxy when the request has been captured, then run:")
    print(f"  python3 {sys.argv[0]} seed-from-capture --in {out_path} \\")
    print("    --out /Users/akaszubski/Dev/local-claude-code-mlx/bench/cases/seed.warm.json")
    print()
    os.execvp(
        sys.executable,
        [
            sys.executable,
            str(CAPTURE_SERVER),
            "--out",
            str(out_path),
            "--port",
            str(args.port),
        ],
    )
    # unreachable
    return 0


def cmd_seed_from_capture(args: argparse.Namespace) -> int:
    in_path = Path(args.inp).resolve()
    out_path = Path(args.out).resolve()
    if not in_path.exists():
        print(f"Capture file not found: {in_path}", file=sys.stderr)
        return 2

    payload = json.loads(in_path.read_text())

    system_text = _system_to_text(payload.get("system"))
    if not system_text.strip():
        print(
            "Captured request has no 'system' field (or it is empty). "
            "Re-run capture-start and use a real Claude Code session "
            "(claude --print ...) so the agent system prompt is sent.",
            file=sys.stderr,
        )
        return 3

    messages = payload.get("messages") or []
    if not messages:
        print("Captured request has no 'messages'", file=sys.stderr)
        return 4
    first_user = messages[0]
    if not isinstance(first_user, dict) or "role" not in first_user:
        print("Captured request: messages[0] is malformed", file=sys.stderr)
        return 4

    user_content = first_user.get("content")
    if isinstance(user_content, list):
        # Anthropic content blocks
        flat: list[str] = []
        for blk in user_content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                t = blk.get("text")
                if isinstance(t, str):
                    flat.append(t)
        user_text = "".join(flat)
    elif isinstance(user_content, str):
        user_text = user_content
    else:
        user_text = ""

    total_bytes = len(system_text.encode("utf-8")) + len(user_text.encode("utf-8"))
    if total_bytes < MIN_TOTAL_BYTES:
        print(
            f"Captured request is too small: system+user = {total_bytes} bytes "
            f"(< {MIN_TOTAL_BYTES}). This is the placeholder/toy size; the seed "
            "must come from a real Claude Code session whose agent system "
            "prompt is many KB. Re-run capture-start and trigger a real request.",
            file=sys.stderr,
        )
        return 5

    seed = [
        [
            {"role": "system", "content": system_text},
            {"role": first_user.get("role", "user"), "content": user_text},
        ]
    ]

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(seed, ensure_ascii=False, indent=2))

    # Round-trip validation under the same rules as load_warmup_file.
    reloaded = json.loads(out_path.read_text())
    _validate_warmup_shape(reloaded, source=str(out_path))

    print(f"Wrote {out_path}")
    print(f"  entries: {len(reloaded)}")
    print(f"  system bytes: {len(system_text.encode('utf-8'))}")
    print(f"  user bytes:   {len(user_text.encode('utf-8'))}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s1 = sub.add_parser(
        "capture-start", help="Run the capture proxy server (foreground)"
    )
    s1.add_argument("--port", type=int, default=8765)
    s1.add_argument(
        "--out",
        default="/Users/akaszubski/Dev/local-claude-code-mlx/bench/cases/_capture/req.json",
    )
    s1.set_defaults(func=cmd_capture_start)

    s2 = sub.add_parser(
        "seed-from-capture",
        help="Convert a captured request into bench/cases/seed.warm.json",
    )
    s2.add_argument("--in", dest="inp", required=True)
    s2.add_argument("--out", required=True)
    s2.set_defaults(func=cmd_seed_from_capture)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
