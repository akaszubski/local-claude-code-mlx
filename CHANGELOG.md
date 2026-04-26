# Changelog

All notable changes to the **local-claude-code-mlx umbrella** (this repo, not the sister components). Sister repos have their own changelogs / commit histories.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: dated, since this is an orchestration repo not a library.

## [unreleased] — 2026-04-27

Initial public release. Establishes the umbrella as its own git repo and consolidates the work of the prior session.

### Added

- **Top-level `README.md`** — first-time setup, daily flow, performance knobs, path overrides, diagnostics. Pulls together what was scattered across the sister repos.
- **`ARCHITECTURE.md`** — process layout, port allocations, lifecycle of `localclaude start`, request data flow, state-on-disk inventory, failure-mode recovery table.
- **`bench/`** — A/B harness for cache configurations under realistic Claude Code traffic. Conditions A (baseline), B (warm-prompts), C (+ssd-cache), D (+8-bit KV quant), and **E (+--enable-mtp)** added this release.
- **`bench/.gitignore`** — excludes `runs/` (per-run artefacts) and `cases/seed.warm.json` (user-captured Claude Code request — contains personal CLAUDE.md / MCP inventory / home paths; regenerate per machine).

### Changed (sister repos — committed in their own repos, summarised here)

- **`localclaude` script** (`akaszubski/localclaude` 0511358):
  - Auto-starts the OrbStack engine and the `localclaude-searxng` container if either is down. Idempotent fixes only — never destructive. Stale-mount errors print a `docker rm -f && docker compose up -d` recipe instead of running it.
  - **Default-on `--ssd-cache-dir ~/.localclaude/ssd-cache --ssd-cache-max-gb 20`** for every profile. Persists prefix cache across server restarts so cold restarts skip the system-prompt + tool-definition prefill. Override with `LOCALCLAUDE_SSD_CACHE_DIR=off` (or relocate via the same env var) and `LOCALCLAUDE_SSD_CACHE_MAX_GB`.
  - README rewrite: documents missing commands (`cc`, `doctor`, `test`), the `coder-480` profile, `-allowlist` presets, OrbStack prereq, the new SSD cache defaults, the `LOCALCLAUDE_EXTRA_VLLM_ARGS` escape hatch, and path overrides.
- **`searxng-mcp` README** (`akaszubski/searxng-mcp` e45ad97):
  - Fixed wrong "use with localclaude" advice. Previously told users to run `localclaude -allowlist all` to keep MCP tools — but the default `code` allowlist already includes `mcp__searxng__search` / `mcp__searxng__fetch`, so this was nudging users into the slowest prefill path for no reason.
  - Updated install path for the umbrella context; standalone path kept as fallback.

### Fixed (in `bench/run.sh`)

- **Harness now captures stdout on `claude --print` failures.** Previously only stderr was logged; non-zero `claude` exits typically have empty stderr and the actual error JSON on stdout. The earlier "empty C/D cells for cases 03/04" run was undiagnosable as a result. Now prints both, truncated, plus the `returncode`.

### vllm-mlx fork patches (the actual reason this stack is fast)

`localclaude` always runs the **local source checkout** of `vllm-mlx`, not the PyPI build. The fork (currently `akaszubski/vllm-mlx`, branched from `waybarrios/vllm-mlx`) carries five patches that aren't upstream yet. They turn ~50s prefill into ~3-5s prefill on an 80K-token Claude Code request — without them the local stack is barely usable.

| Patch | Commit | Flag(s) | What it does |
|---|---|---|---|
| Anthropic /v1/messages prompt optimizer | `818f3fcb` | `--optimize-prompts` | Master switch for the optimizer. Off by default upstream; localclaude turns it on. |
| Tool allowlist | `818f3fcb` | `--optimize-tool-allowlist <csv>` | Drops tool definitions whose names aren't on the list. The default `code` allowlist sends 33 tools (vs 274+ otherwise). |
| Tool description stubs | `818f3fcb` | `--optimize-stub-tools` | Replaces verbose tool descriptions and JSON schemas with short stubs. Combined with the allowlist: ~98% prefill-token reduction (~195K chars → ~3.5K). |
| Auto-disable thinking on tool calls | `b680dc20` | (automatic) | Forces `enable_thinking=false` for any request carrying `tools`. Lets reasoning models (Qwen3-Instruct, DeepSeek-R1) work as agents instead of emitting `<think>` blocks. |
| Stubs for 11 more Claude Code 2.x native tools | `ae25fb83` | (automatic) | Hand-tuned short stubs for `EnterWorktree`, `CronCreate`, `TaskCreate`, etc. Claude Code 2.1+ adds these natively; without the patch the optimizer falls back to verbose schemas for them. |

These patches are intended to land upstream eventually. Until they do, `pip install vllm-mlx` won't have them — that's why the umbrella README's setup says `cd vllm-mlx && pip install -e .` rather than `pip install vllm-mlx`.

Documented in detail at [vllm-mlx/docs/guides/optimizer.md](https://github.com/akaszubski/vllm-mlx/blob/main/docs/guides/optimizer.md) (the fork).

### Decisions (with reasoning)

#### SSD KV cache: **default-on**

Why: Cold-restart wins. After `localclaude stop` (or a Mac reboot), the next `start` previously had to recompute the prefix cache for the system prompt + tool definitions — ~20-30s of dead time before the first useful token. With the SSD tier on, the same pages are reloaded from disk in <1s.

Cost: Up to 20 GB of disk (capped). Quantitative win shown in `bench/runs/20260426-213941`: condition C `03_cc_explain_readme` repeat-call dropped from baseline-class numbers to 7906 ms (~3× speedup over no cache).

Risk: None observed in normal use. Disable with `LOCALCLAUDE_SSD_CACHE_DIR=off` if you're disk-constrained.

#### KV-cache 8-bit quantization: **opt-in only**

Why not default: Real bug found this session — `_QuantizedCacheWrapper` doesn't implement `state`, so `mlx_lm.save_prompt_cache` fails on shutdown with `'_QuantizedCacheWrapper' object has no attribute 'state'`. Combined with the SSD-cache default, this means **6/7 cache entries silently fail to persist** on shutdown, defeating the SSD tier's value across restarts.

Tracked upstream: [`waybarrios/vllm-mlx#443`](https://github.com/waybarrios/vllm-mlx/issues/443). Will revisit defaults once that lands.

Halving KV memory is real and useful when memory pressure is the bottleneck — the flag works in-process. The breakage is only on the disk-persistence path.

#### Warm-prompts: **opt-in only**

Why not default: Architectural blocker — the seed file is project-specific. The bench harness uses `bench/cases/seed.warm.json` (captured from one specific Claude Code session in this repo). There's no obvious "default seed" that's right for every project; a wrong seed wastes prefill on cache entries the user won't reuse, and a missing seed errors out at startup.

Future: per-profile seed-capture flow (capture once per project, stash in `~/.localclaude/seeds/<profile>.json`, point at it automatically). Not built yet.

#### MTP (speculative decoding via `--enable-mtp`): **opt-in only, profile-gated**

Why not default: Only fires on profiles whose model has MTP heads (Qwen3-Next family, Qwen3.5/3.6). On `coder` (default profile, Qwen3MoE base) vllm-mlx logs `[MTP] MTP validation failed — --enable-mtp will be ignored`. So default-on is a no-op there.

Future: Default-on for `coder-next` and `qwen36` profiles after `bench/run.sh --profile coder-next --conditions A,E` validates the 2-3× decode-speed claim on this hardware. Not benched yet.

### Issues filed during this session

| Repo | # | Class | Summary |
|---|---|---|---|
| akaszubski/autonomous-dev | [#977](https://github.com/akaszubski/autonomous-dev/issues/977) | enhancement | scaffold-doctor — detect partial autonomous-dev installs (missing PROJECT.md, etc.) |
| akaszubski/autonomous-dev | [#978](https://github.com/akaszubski/autonomous-dev/issues/978) | bug/security | fixture sanitizer — block personal CLAUDE.md / home paths / MCP inventory leaks in committed test fixtures |
| akaszubski/autonomous-dev | [#979](https://github.com/akaszubski/autonomous-dev/issues/979) | enhancement | audit-context — token-cost breakdown for captured Claude Code requests |
| waybarrios/vllm-mlx | [#443](https://github.com/waybarrios/vllm-mlx/issues/443) | bug | `--kv-cache-quantization` breaks prefix-cache persistence — `_QuantizedCacheWrapper` missing `.state` |

### Out of scope / deferred

- **MTP bench validation on `coder-next`**. Requires switching the running profile (~minutes of model load) and re-running the harness with `--conditions A,E`.
- **Submodule wiring**. The umbrella gitignores the sister repos; first-time setup currently means three `git clone` commands. Submodules would let one clone of this umbrella reproduce the whole layout — worth doing if a second machine starts maintaining this stack, not worth doing solo.
- **Per-profile warm-prompts seeds** (see decision above). Build when the manual `LOCALCLAUDE_EXTRA_VLLM_ARGS` workflow gets annoying.
