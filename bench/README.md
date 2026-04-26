# bench

A/B harness for vllm-mlx cache optimizations under realistic Claude Code traffic.
macOS first. Plain bash + Python stdlib, no pip dependencies.

## Usage

```bash
# 1) One-time: capture a real Claude Code request as the warm-prompts seed
python3 bench/capture_seed.py capture-start
# in another terminal, point claude at the proxy and trigger a real request:
#   ANTHROPIC_BASE_URL=http://127.0.0.1:8765 ANTHROPIC_API_KEY=x \
#     claude --print "list files in this repo and explain what it does"
# Ctrl-C the proxy, then convert:
python3 bench/capture_seed.py seed-from-capture \
    --in  bench/cases/_capture/req.json \
    --out bench/cases/seed.warm.json

# 2) Smoke (under 90s, condition A only)
bench/run.sh --smoke

# 3) Full matrix
bench/run.sh

# Useful flags
bench/run.sh --conditions A,B            # subset
bench/run.sh --cases 1,2 --trials 3
bench/run.sh --no-post-restart           # skip case 5
bench/run.sh --dry-run                   # show plan only
```

Output goes to `bench/runs/<timestamp>/` containing:
- `manifest.json` — parameters of the run
- `<COND>.server.log` — captured server stdout/stderr per condition
- `raw.jsonl` — one record per (condition, case, trial)
- `raw_with_ttft.jsonl` — same, with TTFT backfilled from logs
- `summary.md` — human-readable report

## Step 0 walkthrough

The bench needs `bench/cases/seed.warm.json` to be a real Claude Code system
prompt (typically tens of KB). The shipped placeholder is rejected by `run.sh`.

`bench/capture_seed.py capture-start` runs the existing
`vllm-mlx/scripts/capture_server.py` proxy. Point Claude Code at it, trigger
one realistic request, then `seed-from-capture` flattens the captured
Anthropic-style request into the warm-prompts shape:
`[[{"role":"system","content":"..."},{"role":"user","content":"..."}]]`.

The conversion fails fast if the captured request is missing `system` or if
`system + first user message < 5000 bytes` (the toy size).

## Conditions

| Cond | EXTRA_VLLM_ARGS                                                                                                |
|------|----------------------------------------------------------------------------------------------------------------|
| A    | _(none — baseline)_                                                                                            |
| B    | `--warm-prompts <seed.warm.json>`                                                                              |
| C    | B + `--ssd-cache-dir <run>/.ssdcache`                                                                          |
| D    | C + `--kv-cache-quantization --kv-cache-quantization-bits 8`                                                   |
| E    | D + `--enable-mtp` (Multi-Token Prediction; speculative decoding via built-in MTP heads)                       |

These are passed via `LOCALCLAUDE_EXTRA_VLLM_ARGS`, which `localclaude/localclaude`
forwards to `vllm-mlx serve` (extension point already in place).

### When does condition E actually fire?

`--enable-mtp` only changes behavior on models that ship MTP heads:

| Profile        | MTP weights present? |
|----------------|----------------------|
| `coder`        | No (Qwen3MoE base)   |
| `coder-next`   | Yes (Qwen3-Next)     |
| `coder-480`    | Yes (Qwen3-Next)     |
| `instruct`     | No (Qwen3MoE)        |
| `qwen36`       | Likely yes (Qwen3.6) |
| `gemma4`       | No                   |

On profiles without MTP, vllm-mlx logs `[MTP] MTP validation failed —
--enable-mtp will be ignored` at startup and condition E collapses to
identical behavior as D. The bench harness still records the run so the
matrix is complete; flag it as a no-op in the report.

To actually validate MTP, run with a supported profile:

```bash
bench/run.sh --profile coder-next --conditions A,E
```

## Cases

| ID | Type           | Source                        | Notes                                              |
|----|----------------|-------------------------------|----------------------------------------------------|
| 1  | curl           | `01_curl_hello.json`          | Tiny prompt, no tools. Pure prefill+decode signal. |
| 2  | claude --print | `02_cc_list_files.txt`        | Single-turn, file listing.                         |
| 3  | claude --print | `03_cc_explain_readme.txt`    | Read+summarize, multi-turn likely.                 |
| 4  | claude --print | `04_cc_multiturn.txt`         | Multi-step (list → measure → suggest).             |
| 5  | post-restart   | (re-runs case 2 once)         | Only on conditions C/D, after a stop+start.        |

Each case runs `--trials` times (default 5). Case 5 runs exactly once per
condition C/D and probes whether the SSD cache hot-loads after a restart.

## first-call vs repeat-call

The "first-call" column is the very first request after the server is healthy
— for conditions B/C/D the prefix cache has already been seeded by `--warm-prompts`,
so "B first-call" is faster than "A first-call" by exactly the warmup benefit.
The "repeat-call" column is the median of trials 2..N (with slowest discarded)
and reflects steady-state cache behavior. Variance is reported as IQR; cells
flagged ⚠ have IQR/median > 0.5, meaning the signal is noisy and the comparison
is not reliable on this run.

## Why a separate harness

vllm-mlx ships two existing benchmarks:
- `vllm_mlx/benchmark.py` — single-process throughput at saturation.
- `vllm_mlx/bench_serve.py` — multi-client serving throughput.
Both target tokens/sec at saturation. This harness targets single-user
TTFT and wall-clock under realistic Claude Code traffic, with focus on
prefix-cache effects across server restarts. Use the existing tools for
throughput regressions; use this for cache and TTFT regressions.

## Tests

```bash
cd bench && python3 -m unittest discover tests
bash bench/tests/test_log_offset_sh.sh
```
