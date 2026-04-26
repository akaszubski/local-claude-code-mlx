"""Common helpers: load analyze.py and capture_seed.py as importable modules."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]


def load_module(name: str, file_path: Path):
    spec = importlib.util.spec_from_file_location(name, file_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {file_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def load_analyze():
    return load_module("bench_analyze", BENCH_DIR / "analyze.py")


def load_capture_seed():
    return load_module("bench_capture_seed", BENCH_DIR / "capture_seed.py")
