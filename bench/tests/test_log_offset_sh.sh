#!/usr/bin/env bash
# Sanity test for lib/log_offset.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$HERE")"

# shellcheck source=../lib/log_offset.sh
source "$BENCH_DIR/lib/log_offset.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# nonexistent path → 0
got=$(log_size "/no/such/file/should/exist/$$")
[[ "$got" == "0" ]] || fail "expected 0 for nonexistent, got $got"

# 11-byte fixture
printf "hello world" > "$tmp"
got=$(log_size "$tmp")
[[ "$got" == "11" ]] || fail "expected 11, got $got"

# empty file → 0
: > "$tmp"
got=$(log_size "$tmp")
[[ "$got" == "0" ]] || fail "expected 0 for empty, got $got"

echo "PASS test_log_offset_sh.sh"
