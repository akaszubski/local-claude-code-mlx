# local-claude-code-mlx

Run **Claude Code** against a **local Qwen** model on Apple Silicon, with real
web research and an A/B benchmark harness for cache tuning. No cloud, no API
keys, no rate limits.

**Read also**: [ARCHITECTURE.md](ARCHITECTURE.md) for technical layout and request flow · [CHANGELOG.md](CHANGELOG.md) for what's in this version and why.

## What's in this umbrella

| Component | Repo | What it is |
|---|---|---|
| [`vllm-mlx/`](https://github.com/waybarrios/vllm-mlx) | upstream + fork | The inference server. vLLM-style continuous batching + paged KV cache + prefix cache + SSD tiering on Metal. Exposes OpenAI `/v1/*` and Anthropic `/v1/messages` from one process. **Use the local source checkout** — the fork carries the prompt optimizer, tool stubs, and thinking-gate patches that make local Claude actually fast (see "vllm-mlx fork patches" below). |
| [`localclaude/`](https://github.com/akaszubski/localclaude) | own repo | Single-command lifecycle wrapper. Boots `vllm-mlx` with the right model + tool parser per profile, prints the `claude` connect command, manages stop/restart/status. Auto-starts the SearXNG container. |
| [`searxng-mcp/`](https://github.com/akaszubski/searxng-mcp) | own repo | Tiny MCP server that gives Claude Code a `mcp__searxng__search` tool backed by a local SearXNG container. Replaces Anthropic's server-side `WebSearch` (which no-ops against local LLMs). |
| [`bench/`](bench/) | this repo | A/B harness that measures wall-clock + TTFT under realistic Claude Code traffic across five cache configurations (baseline / `--warm-prompts` / `+--ssd-cache-dir` / `+--kv-cache-quantization` / `+--enable-mtp`). |

```
        ┌──────────────┐         ┌────────────────────────┐
        │ Claude Code  │ ──HTTP──▶│ vllm-mlx serve <model> │ ── MLX/Metal
        │   CLI 2.x    │         │  :8000                 │       on M-series
        └──────────────┘         └────────────────────────┘
              │                         ▲
              │ MCP                     │ stdout/stderr
              ▼                         │
       ┌─────────────────┐       ┌──────────────────┐
       │ searxng-mcp     │       │ localclaude      │
       │  run.sh         │       │  (bash wrapper)  │
       └─────────────────┘       └──────────────────┘
              │
              ▼
       ┌──────────────────────┐
       │ SearXNG container    │
       │ (Docker / OrbStack)  │
       │  :8080 loopback      │
       └──────────────────────┘
```

## First-time setup

### Recommended: one script does it all

```bash
git clone https://github.com/akaszubski/local-claude-code-mlx.git ~/Dev/local-claude-code-mlx
cd ~/Dev/local-claude-code-mlx
./install.sh
```

`install.sh` is **Mac-only** and idempotent — safe to re-run. It walks through 8 phases:

1. Pre-flight: verifies macOS + Apple Silicon + RAM.
2. System deps: checks/installs `git`, `python3`, `claude` CLI, OrbStack via Homebrew. (You need Homebrew already — `https://brew.sh`.)
3. Clones sister repos (`vllm-mlx`, `localclaude`, `searxng-mcp`) into umbrella siblings.
4. Python deps: `pip install -e ./vllm-mlx`, plus a dedicated `searxng-mcp/.venv` with `mcp` + `httpx`.
5. Starts the OrbStack engine and brings up the `localclaude-searxng` container.
6. Registers `searxng` MCP server with Claude Code (`claude mcp add`).
7. Appends a `PATH` line to your shell rc so `localclaude` is callable from anywhere (prompts before editing).
8. Runs `localclaude doctor` to verify everything's healthy.

Flags: `--yes` (auto-confirm prompts), `--no-path` (skip shell rc edit), `--no-mcp` (skip MCP registration), `--dry-run` (show what would happen, change nothing). `./install.sh --help` for details.

### Manual setup (if you'd rather)

If you want to step through it yourself or you're on a non-standard layout:

<details>
<summary>Show manual steps</summary>

#### Hardware / OS prereqs

- Apple Silicon Mac (M1+). Recommended ≥32 GB RAM for `coder` profile, ≥64 GB for `coder-next` 8-bit, ≥256 GB for `coder-480`.
- macOS 14+.

#### Clone the umbrella + sister repos

```bash
mkdir -p ~/Dev/local-claude-code-mlx && cd ~/Dev/local-claude-code-mlx
git clone https://github.com/akaszubski/local-claude-code-mlx.git .
git clone https://github.com/waybarrios/vllm-mlx.git
git clone https://github.com/akaszubski/localclaude.git
git clone https://github.com/akaszubski/searxng-mcp.git
```

After this, `localclaude` auto-resolves all sister paths from its own location — no env vars needed unless you've moved things.

#### Install dependencies

```bash
# Inference server — use the local checkout (carries optimizer + thinking-gate
# patches that ship before they reach PyPI):
cd vllm-mlx && pip install -e . && cd ..

# Claude Code CLI + OrbStack:
brew install claude
brew install --cask orbstack
orb start
```

#### Bring up SearXNG (web search backend)

```bash
cd searxng-mcp && docker compose up -d
curl -sf http://127.0.0.1:8080/ >/dev/null && echo "SearXNG up"
```

Container is named `localclaude-searxng` with `restart: unless-stopped`, so it auto-comes-back after reboots once OrbStack is running.

#### Register the MCP server with Claude Code

```bash
claude mcp add searxng -- $(pwd)/run.sh   # from inside searxng-mcp/
```

#### Put `localclaude` on your PATH

```bash
echo 'export PATH="'"$(pwd)"'/localclaude:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

(Run from the umbrella root.)

</details>

## Daily flow

```bash
# Terminal 1 — server (cd to whatever project you want claude to work in)
cd ~/Dev/myproject
localclaude start coder
# Boots vllm-mlx, ensures SearXNG container is up (auto-starts OrbStack
# engine + container if either is down), prints the claude connect command.

# Terminal 2 — Claude Code
localclaude cc
# Or paste the env-var command that `start` printed.
```

When done:

```bash
localclaude stop          # kills server, prefix cache lost
# Or just leave it running — keeps the prefix cache warm.
```

## Benchmarks

Measured on this stack across past sessions. Numbers are pulled from live server logs and the [`vllm-mlx/docs/benchmarks/`](https://github.com/akaszubski/vllm-mlx/tree/main/docs/benchmarks) reference suite. Anything that's a design target rather than a measurement is flagged.

### Decode tokens/sec (single stream, small prompt)

| Model | Quant | Hardware | Decode tok/s | TTFT (warm) |
|---|---|---|---:|---:|
| Qwen3-Coder-30B-A3B-Instruct (`coder` profile) | 4-bit | M4 Max 128 GB | **107–120** | ~70 ms |
| Qwen3-30B-A3B-Instruct-2507 (`instruct`) | 4-bit | M4 Max 128 GB | **123–127** | ~127 ms |
| Qwen3-Coder-480B-A35B (`coder-480`) | 4-bit | M3 Ultra 512 GB | **16–17** | (cold prefill is the killer — see below) |
| Llama-3.2-3B-Instruct (reference) | 4-bit | M4 Max | 200 | 81 ms |
| Qwen3-0.6B (reference) | 8-bit | M4 Max | 402 | 59 ms |
| Nemotron-3-Nano-30B-A3B (reference) | 6-bit | M4 Max | 122 | 72 ms |

### TTFT under real Claude Code traffic (the number that matters most for agent UX)

| Model | Prompt size | Cache state | First-token latency |
|---|---:|---|---:|
| Qwen3-Coder-30B-A3B-4bit (M4 Max) | ~33 tok | warm cache | 70–400 ms |
| Qwen3-Coder-30B-A3B-4bit (M4 Max) | 19,113 tok / 19,091 cached | prefix-cache **HIT** | **3.2 s** |
| Qwen3-Coder-30B-A3B-4bit (M4 Max) | 4,694 new / 5K cached | partial hit | 5.2 s |
| Qwen3-Coder-30B-A3B-4bit (M4 Max) | ~22K | **cold** (new project) | **30 s** |
| Qwen3-Coder-480B-A35B-4bit (M3 Ultra) | 19,004 tok | cold | **95.8 s** |
| Qwen3-Coder-480B-A35B-4bit (M3 Ultra) | 22,469 tok / 2,508 cached | mostly miss (project switch) | **117.4 s** |

Takeaway: **prefix-cache hits drop TTFT by ~10×** on the 30B coder model (3.2 s vs 30 s). On the 480B model the cold-prefill penalty is so steep (~95–117 s) that the SSD-cache default and CLAUDE.md hygiene matter much more there than on smaller models.

### Continuous batching wins (M4 Max, vllm-mlx benchmark suite)

| Model | Single stream | 5-stream batch | Speedup |
|---|---:|---:|---:|
| Qwen3-30B-A3B-4bit | 98.1 tok/s | **233.3 tok/s** | 2.38× |
| Llama-3.2-1B-Instruct-4bit | 299.1 | **613.0** | 2.05× |
| Qwen3-0.6B-8bit | 328.1 | **1111.8** | 3.39× |

Paged cache adds another ~1.1× on top of batching (681 → 766 tok/s, 20-req test).

### Optimizer ON vs OFF (design target, not yet a controlled A/B)

| Configuration | Tools sent | First-turn prefill (claim) |
|---|---:|---:|
| Default `code` allowlist (33 tools, stubs on) | 33 | **~3 s** |
| All MCP tools, no allowlist (~277 tools) | 277 | **~50 s for ~80K tokens** |

⚠ **Caveat**: This is the documented design target derived from token-count math + log observations on Qwen3-Coder-30B-A3B-4bit. It is **not yet a controlled paired-trial measurement** in the bench harness. The closest direct measurement is the 30 s cold prefill at 22 K tokens above (Section 2).

### Cache configuration A/B (preliminary — small n)

From `bench/runs/20260426-151203/`. Wall-clock for `claude --print` round-trips. Caveats: trial counts 1–5 per cell, C/D mostly errored on cases 03/04 (root cause: missing test fixture at run-time, since fixed). Treat as directional only.

| Cond | Case | first-call wall (ms) | repeat wall (ms) |
|---|---|---:|---:|
| A (baseline) | 02_cc_list_files | 10,579–44,592 | 26,355 |
| B (+`--warm-prompts`) | 02_cc_list_files | 11,133–25,160 | **11,184** |
| C (+`--ssd-cache-dir`) | 02_cc_list_files | 46,767 | 27,699 |
| D (+`--kv-cache-quantization`) | 02_cc_list_files | 30,424–46,817 | 27,919 |

Cleanest signal: **`--warm-prompts` repeat wall 11.2 s vs baseline 26.4 s** (~2.4× faster), but n=1 — needs more trials to claim definitively. Re-run after the harness fix landed in `20260426-213941` confirmed C is functional and ~3× faster than baseline on `cc_explain_readme` (case 3) — see that summary file for details.

### What we have NOT measured (be honest)

- No controlled optimizer-on vs optimizer-off TTFT comparison in the bench harness (the 50 s vs 3 s claim is design target, not paired A/B).
- No per-quantization sweep on the same model (e.g. 4-bit vs 8-bit Qwen3-Coder-30B on identical hardware).
- No wired-memory / RSS time series for the leak in [`vllm-mlx#442`](https://github.com/waybarrios/vllm-mlx/issues/442) — only point-in-time KV-cache MB readings from scheduler logs.
- No MTP (`--enable-mtp`) numbers on `coder-next` / `qwen36` profiles. Bench condition E is wired but the run hasn't been done yet.

If you re-run the bench, results land in `bench/runs/<timestamp>/summary.md` and can be folded back into this section.

## Keep your CLAUDE.md files lean

Claude Code embeds two CLAUDE.md files in **every** request's system prompt:
- **Global**: `~/.claude/CLAUDE.md` — sent on every request from every project.
- **Project**: `./CLAUDE.md` (per repo) — sent on every request from that project.

Both are inside the cacheable prefix that vllm-mlx's prefix cache hashes. **Each token you add costs you twice**:

1. **Prefill cost**: every fresh request pays for those tokens at prefill speed (slow for cold starts).
2. **Cache invalidation across projects**: switching projects means a different `./CLAUDE.md` content → different prefix → cache miss → ~95–117s cold prefill on Qwen3-Coder-480B in our testing. The bigger your CLAUDE.mds, the more tokens cache-miss when you switch.

Practical guidance from our profiling:

| Do | Don't |
|---|---|
| Keep global `~/.claude/CLAUDE.md` under ~2 KB. Personal preferences only. | Dump every workflow rule, framework, philosophy doc in there. It's sent with every request, everywhere. |
| Keep project `./CLAUDE.md` under ~3 KB. Truly project-specific facts only (build command, test runner, deploy quirks). | Mirror your README into CLAUDE.md. Claude can `Read` files on demand. |
| Use sub-docs (`docs/*.md`) for deep reference and let Claude pull them when needed. | Keep "future plans" or "TODO" sections in CLAUDE.md. They invalidate the cache and aren't actionable. |
| Audit periodically: `wc -c ~/.claude/CLAUDE.md ./CLAUDE.md`. | Forget global CLAUDE.md exists. It's the easiest one to bloat. |

If you want a precise breakdown of where your prefix tokens are going, the upstream issue [`autonomous-dev#979`](https://github.com/akaszubski/autonomous-dev/issues/979) tracks an `audit-context` command for this.

Note also that **MCP server tool definitions dwarf CLAUDE.md** in most setups — the optimizer's tool allowlist (above) is the bigger lever. CLAUDE.md hygiene is the second-biggest.

## ⚠ Operational caveats (read before exposing this beyond loopback)

`localclaude` defaults to binding `127.0.0.1` for a reason. Surfaced from open upstream issues:

| Issue | Risk | Mitigation |
|---|---|---|
| [`waybarrios/vllm-mlx#68`](https://github.com/waybarrios/vllm-mlx/issues/68) | `vllm-mlx` ships with no auth, vanilla `serve` defaults to `0.0.0.0`, and `/v1/messages` is open. ~25 vulns documented including SSRF in multimodal URL fetch and `trust_remote_code=True` defaults. | Keep `localclaude start` on its default `127.0.0.1` bind unless you understand the implications. If you need LAN access (e.g. M3 Ultra remote profile), pass `-bind <mesh-ip>` only on a trusted network and consider also setting `--api-key` via `LOCALCLAUDE_EXTRA_VLLM_ARGS`. **Do not expose to the public internet.** |
| [`waybarrios/vllm-mlx#442`](https://github.com/waybarrios/vllm-mlx/issues/442) | **MLX wired/Metal memory grows unbounded under sustained traffic.** Python RSS underreports — `ps`/Activity Monitor won't catch it. Eventually `kIOGPUCommandBufferCallbackErrorOutOfMemory`. | Restart the server periodically on long-running sessions (`localclaude restart`). Watch *wired memory* (`memory_pressure`, `vm_stat`), not RSS. Symptom: gradually-rising responses, then a hard kill. |
| [`waybarrios/vllm-mlx#380`](https://github.com/waybarrios/vllm-mlx/issues/380) | **Gemma 4 profile is currently broken** — multiple parser/template bugs cause nonsense output under continuous batching, plus stray `&lt;channel&#124;&gt;` tokens from the reasoning parser. | Don't use the `gemma4` profile until upstream fix lands. Stick with `coder` / `coder-next` / `qwen36`. |
| [`waybarrios/vllm-mlx#431`](https://github.com/waybarrios/vllm-mlx/issues/431) | Streaming whitespace-only deltas dropped under the generic `qwen` and `minimax` tool parsers — markdown layout collapses mid-stream. The `qwen3_coder` parser is unaffected. | Affects `instruct` / `qwen36` profiles (which use `--tool-call-parser qwen`). Either accept the cosmetic glitch or wait for the imminent upstream fix. `coder` and `coder-next` use `qwen3_coder` and are unaffected. |
| [`waybarrios/vllm-mlx#422`](https://github.com/waybarrios/vllm-mlx/issues/422) | MoE MTP load fails (`dequantize` triggered on bare-key tensors) — affects MTP weights generated for Qwen3.5/3.6 MoE targets via `add_mtp_weights_qwen35.py`. | If you generate MTP weights for `coder-next` / `qwen36`, apply the one-line patch from the issue thread or pin generation away from MoE targets until merged. |

These are all upstream `waybarrios/vllm-mlx` issues; track them there for fix progress.

## vllm-mlx fork patches (the reason this is fast)

`localclaude` always runs the **local source checkout** of `vllm-mlx`, not the
PyPI build. The fork (currently at `akaszubski/vllm-mlx`, branched off
`waybarrios/vllm-mlx`) carries five patches that aren't upstream yet — and
they're the difference between *barely usable* and *fast* local Claude:

| Patch | Commit | Flag(s) | Why it matters |
|---|---|---|---|
| **Anthropic /v1/messages prompt optimizer** | `818f3fcb` | `--optimize-prompts` | Master switch for all the optimizer transforms below. Off by default upstream; `localclaude` enables it. |
| **Tool allowlist** | `818f3fcb` | `--optimize-tool-allowlist <csv>` | Drops tool definitions whose names aren't on the list. Claude Code 2.x ships with 274+ tools (MCP servers + native); without an allowlist, every request carries ~100K tokens of tool schemas. The default `code` allowlist sends 33. |
| **Tool description stubs** | `818f3fcb` | `--optimize-stub-tools` | Replaces verbose tool descriptions and JSON schemas with short stubs. Combined with the allowlist, ships ~3.5K chars vs ~195K — **~98% prefill reduction**. |
| **Auto-disable thinking on tool calls** | `b680dc20` | (automatic) | Reasoning models like Qwen3-Instruct emit `<think>` blocks. For tool-using requests this means the model spends tokens reasoning instead of committing tool calls. The patch auto-disables `enable_thinking` when the request carries `tools`. Lets Qwen3-Coder + reasoning parser work as an agent. |
| **11 more Claude Code 2.x native tool stubs** | `ae25fb83` | (automatic) | Hand-tuned short stubs for tools like `EnterWorktree`, `CronCreate`, `TaskCreate` etc. that Claude Code ships in 2.1+. Without these the optimizer falls back to verbose schemas for those tools. |

Practical impact (M4 Max, `coder` profile, ~80K-token Claude Code request):

| Configuration | First-prefill |
|---|---|
| Vanilla `vllm-mlx serve` (no optimizer) | ~50s |
| With `--optimize-prompts --optimize-stub-tools` + `code` allowlist | ~3-5s |
| Same + warm-prompts | <1s |

This is why `localclaude` is mandatory if you want the local stack to feel like the cloud Claude. The fork patches are intended to land upstream; until they do, the local checkout is the way to get them.

See [vllm-mlx/docs/guides/optimizer.md](https://github.com/akaszubski/vllm-mlx/blob/main/docs/guides/optimizer.md) in the fork for the full optimizer reference.

## Performance tuning

`vllm-mlx` ships four cache / decode optimizations. Their default state in `localclaude` profiles:

| Knob | Flag | Default | What it buys you | Why this default |
|---|---|---|---|---|
| SSD cache tiering | `--ssd-cache-dir <path>` `--ssd-cache-max-gb <N>` | **on** (since 2026-04-26) | Persists prefix cache to disk; cold restarts reuse it (~3× speedup on repeat-call) | No measured downside; cap'd at 20 GB |
| Warm-prompts seeding | `--warm-prompts <seed.json>` | opt-in | Removes the 30s "first prompt" prefill stall via a pre-warmed cache | Seed file is project-specific; no sensible default |
| 8-bit KV quantization | `--kv-cache-quantization --kv-cache-quantization-bits 8` | opt-in | Halves KV memory pressure | **Bug**: incompatible with cache persistence ([waybarrios/vllm-mlx#443](https://github.com/waybarrios/vllm-mlx/issues/443)) — defeats SSD cache default if combined |
| MTP (speculative decoding) | `--enable-mtp` | opt-in, profile-gated | 2-3× decode speed on supported models | Only applies to Qwen3-Next / Qwen3.5/3.6; auto-disabled on other models |

See [CHANGELOG.md](CHANGELOG.md) for the reasoning behind each default.

### Override the default + enable opt-ins

```bash
# Disable / relocate the SSD cache:
LOCALCLAUDE_SSD_CACHE_DIR=off localclaude start coder
LOCALCLAUDE_SSD_CACHE_MAX_GB=50 localclaude start coder

# Enable opt-in knobs via the bench escape hatch:
LOCALCLAUDE_EXTRA_VLLM_ARGS="--warm-prompts $(pwd)/bench/cases/seed.warm.json --enable-mtp" \
  localclaude start coder
```

### Benchmark before changing defaults

```bash
bench/run.sh                # full A/B/C/D/E matrix
bench/run.sh --smoke        # ~90s sanity
bench/run.sh --conditions C,D --cases 3,4 --trials 2   # focused diagnostic
```

See [`bench/README.md`](bench/README.md) for harness details and how to capture a fresh `seed.warm.json` for your project.

## Path overrides

`localclaude` resolves sister components from its own location. Override
individually if you've moved them:

```bash
LOCALCLAUDE_WORKSPACE_DIR=/path/to/workspace
LOCALCLAUDE_VLLM_MLX_DIR=/path/to/vllm-mlx
LOCALCLAUDE_SEARXNG_MCP_DIR=/path/to/searxng-mcp
```

## Diagnose

```bash
localclaude doctor   # full stack health check
localclaude test     # end-to-end smoke (real model query + decoder-collapse detection)
localclaude status   # what's running + connect command + recent log lines
```

## State on disk

| Path | What it is |
|---|---|
| `~/.localclaude/.active` | Last-used profile config (read by `restart` / `cc` / `status`) |
| `~/.localclaude/logs/<profile>.log` | Per-profile server logs |
| `~/.localclaude/ssd-cache/` | (if enabled) persistent KV cache pages |
| `~/.cache/huggingface/` | Model weights (handled by `huggingface_hub`) |

## License

Each component carries its own LICENSE file. `vllm-mlx`, `localclaude`, and
`searxng-mcp` are Apache 2.0.
