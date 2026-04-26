# Architecture

How the four components fit together when you run `localclaude start coder` and then talk to your local Claude Code.

## Components

| Component | Repo | Role | Talks to |
|---|---|---|---|
| **vllm-mlx** | `waybarrios/vllm-mlx` | Inference server: `vllm-mlx serve …` exposes OpenAI `/v1/*` and Anthropic `/v1/messages` on `:8000`. Continuous batching, paged KV cache, prefix cache, optional SSD tier. | MLX/Metal kernels |
| **localclaude** | `akaszubski/localclaude` | Bash lifecycle wrapper: stop/start/status/restart, profile→model+parser resolution, auto-bring-up of the SearXNG container, port-8000 single-server invariant. | `vllm-mlx` (subprocess), `docker`/`orb` (CLI), `claude` (subprocess via `cc`) |
| **searxng-mcp** | `akaszubski/searxng-mcp` | Tiny MCP server exposing `mcp__searxng__search` and `mcp__searxng__fetch` tools. Replaces Anthropic's server-side `WebSearch`, which no-ops against a local LLM. | SearXNG container on `:8080` |
| **bench/** | (this repo) | A/B harness that drives realistic Claude Code traffic through the stack and measures wall-clock + TTFT under different cache configurations. | `localclaude` (subprocess) → everything below it |

## Process and port layout

```
   ┌────────────────────────────────────────────────────────┐
   │ Mac host (Apple Silicon, macOS 14+)                    │
   │                                                        │
   │  ┌──────────────────┐    ┌──────────────────────────┐  │
   │  │ Claude Code CLI  │ ── │ ANTHROPIC_BASE_URL=:8000 │  │
   │  │  (claude --print │    │ ANTHROPIC_API_KEY=…      │  │
   │  │   or interactive)│    │ ANTHROPIC_MODEL=qwen…    │  │
   │  └────────┬─────────┘    └──────────────────────────┘  │
   │           │ HTTP                                       │
   │           ▼                                            │
   │  ┌────────────────────────────────────────────────┐    │
   │  │ vllm-mlx serve  :8000  (Python/MLX)            │    │
   │  │   /v1/messages  (Anthropic)                    │    │
   │  │   /v1/chat/completions  (OpenAI)               │    │
   │  │   /v1/embeddings  /v1/rerank  /metrics         │    │
   │  │                                                │    │
   │  │  Caches:                                       │    │
   │  │   1. Paged KV (RAM)          ← always on       │    │
   │  │   2. Prefix cache (RAM)      ← always on       │    │
   │  │   3. SSD tier   (~/.localclaude/ssd-cache)     │    │
   │  │      ← on by default since 2026-04-26          │    │
   │  └────────────────┬───────────────────────────────┘    │
   │                   │                                    │
   │                   ▼                                    │
   │     MLX → Metal kernels (unified memory)               │
   │                                                        │
   │  ┌──────────────┐  ┌──────────────────────────────┐    │
   │  │ searxng-mcp  │  │ Docker / OrbStack engine     │    │
   │  │  run.sh      │  │ ┌──────────────────────────┐ │    │
   │  │  (stdio MCP) │──│→│ localclaude-searxng :8080│ │    │
   │  └──────────────┘  │ │  (SearXNG image)         │ │    │
   │      ▲             │ └──────────────────────────┘ │    │
   │      │ stdio       └──────────────────────────────┘    │
   │  ┌───┴──────────┐                                      │
   │  │ Claude Code  │  ← reads MCP server registration     │
   │  │ (registered  │     from ~/.claude.json              │
   │  │  via         │                                      │
   │  │  `claude mcp │                                      │
   │  │   add`)      │                                      │
   │  └──────────────┘                                      │
   └────────────────────────────────────────────────────────┘
```

## Lifecycle: what `localclaude start coder` actually does

```
1. Load ~/.localclaude/.active to know last profile, kill any vllm-mlx on :8000.

2. (If allowlist != all) Soft-bring-up SearXNG dependency:
     a. docker info?  No → orb start (if available)
     b. localclaude-searxng container running?  No → docker compose up -d
        from searxng-mcp/. Never destructive — stale-mount errors print
        the docker rm + up -d recipe instead of executing it.

3. Resolve profile → (model, tool_call_parser, reasoning_parser, ctx_window).

4. Build vllm-mlx args:
     vllm-mlx serve <model>
       --host 127.0.0.1 --port 8000
       --continuous-batching
       --enable-auto-tool-choice
       --tool-call-parser <parser>
       --optimize-prompts --optimize-stub-tools
       [--reasoning-parser <name>]
       [--optimize-tool-allowlist <csv>]
       --ssd-cache-dir ~/.localclaude/ssd-cache
       --ssd-cache-max-gb 20
       $LOCALCLAUDE_EXTRA_VLLM_ARGS    ← user opt-ins go here

5. Spawn server detached. Tail log until "Application startup complete"
   or hit a health threshold (300s default; auto-extends on real activity
   like model downloads).

6. Write ~/.localclaude/.active (profile, model, port, log path,
   allowlist, context_window) so cc/restart/status know what's live.

7. Print the claude connect command. Done.
```

`localclaude cc` then sets `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` / `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and execs `claude` in the user's cwd.

## Data flow: a single Claude Code request

```
user types in claude
  │
  ▼
claude builds Anthropic /v1/messages POST:
  - system prompt (Claude Code base ~18-22K tokens)
  - global ~/.claude/CLAUDE.md  (~2K)
  - project ./CLAUDE.md         (variable)
  - tool definitions (filtered by --optimize-tool-allowlist)
  - prior turns
  - new user message
  │ HTTP
  ▼
vllm-mlx /v1/messages
  - Anthropic adapter normalises to internal request
  - PROMPT OPTIMIZER (fork patch, --optimize-prompts):
      a. Tool allowlist — drop tools not on `--optimize-tool-allowlist`
         (33 keep / 240+ drop with default `code` allowlist)
      b. Tool stubs — replace verbose descriptions and JSON schemas with
         short stubs (~195K chars → ~3.5K, 98% reduction)
      c. Thinking gate — for tool-carrying requests, force
         `enable_thinking=false` so reasoning models commit tool calls
         instead of emitting <think> blocks
  - Prefix cache: longest-common-prefix lookup
       hit  → start decoding from cached suffix offset
       miss → SSD tier lookup → disk read or full prefill
  - Continuous-batching scheduler dispatches to BatchedEngine
  - Token stream returned chunk-by-chunk via SSE
  │ HTTP stream
  ▼
claude renders the streamed response, dispatches tool calls
  - Native tools (Read, Edit, Bash…) execute locally
  - mcp__searxng__search → MCP stdio call → searxng-mcp
                              → HTTP to :8080 (SearXNG container)
  - Tool result returns as next /v1/messages turn
```

## vllm-mlx fork patches

`localclaude` runs the local source checkout because five fork-only patches change the practical performance ceiling for Claude Code on a local LLM. Without them, prefill of an 80K-token Claude Code request takes ~50s on M4 Max — effectively unusable. With them, the same request prefills in 3-5s.

| Patch | Commit | Flag(s) | Default in `localclaude` | What it does |
|---|---|---|---|---|
| Anthropic /v1/messages prompt optimizer | `818f3fcb` | `--optimize-prompts` | **on** | Master switch. Enables the three transforms below before the request enters the inference engine. |
| Tool allowlist | `818f3fcb` | `--optimize-tool-allowlist <csv>` | **on** (preset selectable: `minimal` / `code` / `all`) | Drops tool definitions whose names aren't on the allowlist. `code` preset = 33 tools (Claude Code natives + searxng MCP). `minimal` = 6. `all` = no filter. |
| Tool description stubs | `818f3fcb` | `--optimize-stub-tools` | **on** | Replaces verbose tool descriptions and JSON schemas with short stubs. Combined with the allowlist: ~98% fewer prefill tokens. Deterministic so prefix cache hits cleanly. |
| Auto-disable thinking on tool calls | `b680dc20` | (automatic) | **on** | Forces `enable_thinking=false` for any request carrying `tools`. Prevents reasoning models from emitting `<think>` blocks instead of committing tool calls. |
| Stubs for 11 more Claude Code 2.x native tools | `ae25fb83` | (automatic) | **on** | Hand-tuned short stubs for `EnterWorktree`, `CronCreate`, `TaskCreate` etc. Without these the optimizer falls back to verbose schemas for those tools. |

The prefix cache + SSD tier amplify these wins: optimizer transforms produce a deterministic prefix, and the cache reuses it across turns and across server restarts.

These patches are intended to land upstream (`waybarrios/vllm-mlx`); until they do, `pip install vllm-mlx` won't have them and the local checkout is mandatory.

## The 3 (4) cache knobs

| Knob | Flag | Layer | Default | Status |
|---|---|---|---|---|
| Warm-prompts | `--warm-prompts <seed.json>` | Pre-warm prefix cache from a captured Claude Code request at startup | **opt-in** | Real ~3× repeat-call speedup; needs project-specific seed. See `bench/README.md` "Step 0 walkthrough". |
| SSD tier | `--ssd-cache-dir <path>` `--ssd-cache-max-gb <N>` | Spill prefix cache to disk; reload on cold start | **on** (since 2026-04-26) | Default `~/.localclaude/ssd-cache`, 20 GB cap. Override with `LOCALCLAUDE_SSD_CACHE_DIR=off`. |
| KV-quant 8-bit | `--kv-cache-quantization` `--kv-cache-quantization-bits 8` | Halve KV memory pressure | **opt-in** | **Bug**: incompatible with cache persistence (`_QuantizedCacheWrapper.state` missing). Filed as `waybarrios/vllm-mlx#443`. Defeats the SSD-tier default if combined. |
| MTP (speculative) | `--enable-mtp` | Multi-Token Prediction draft heads | **opt-in** | Only active on Qwen3-Next / Qwen3.5/3.6 (`coder-next`, `coder-480`, `qwen36`). Auto-disabled on `coder` (Qwen3MoE base, no MTP heads). Bench coverage: `bench/run.sh --conditions E`. |

Why these defaults? See `CHANGELOG.md` for the full reasoning.

## State on disk

| Path | Owner | What it is |
|---|---|---|
| `~/.localclaude/.active` | localclaude | Last-active profile config (sourced by `cc`/`restart`/`status`) |
| `~/.localclaude/logs/<profile>.log` | localclaude | Per-profile server stdout/stderr |
| `~/.localclaude/ssd-cache/` | vllm-mlx | Persistent SSD KV-cache pages (when default-on; up to 20 GB) |
| `~/.cache/vllm-mlx/prefix_cache/<model>/` | vllm-mlx | Lifespan-persisted prefix cache (in-memory snapshot on shutdown) |
| `~/.cache/huggingface/hub/` | huggingface_hub | Model weights (`huggingface_hub` content-addressed by SHA) |
| `~/.claude.json` | Claude Code | MCP server registrations (used by Claude to know about `mcp__searxng__*`) |
| `<umbrella>/bench/runs/<ts>/` | bench/run.sh | A/B run artefacts (`raw.jsonl`, `summary.md`, per-condition server logs) |
| `<umbrella>/searxng-mcp/searxng-config/settings.yml` | searxng-mcp | Bind-mounted into the SearXNG container as `/etc/searxng/settings.yml` |

## Failure modes and recovery

| Symptom | Likely cause | Recovery |
|---|---|---|
| `localclaude start` warns SearXNG container not running, can't auto-fix | OrbStack engine stopped | `orb start` (script does this automatically when `orb` is on PATH). |
| `localclaude start` warns container exited with code 127 | Stale bind-mount path (e.g. project moved on disk) | `docker rm -f localclaude-searxng && docker compose up -d` from `searxng-mcp/`. |
| `claude --print` exits non-zero with 6-11s wall and 893-byte stdout | Claude Code-side error JSON, not a server issue | Inspect stdout (the harness now captures it; `bench/runs/<latest>/raw.jsonl` `error_message` field). |
| `[cache_persist] failed to save entry N: '_QuantizedCacheWrapper' object has no attribute 'state'` on shutdown | Known bug when `--kv-cache-quantization` is enabled | Don't combine `--kv-cache-quantization` with `--ssd-cache-dir` until upstream fix lands. Tracked as `waybarrios/vllm-mlx#443`. |
| First prompt after `localclaude start` is slow (~30s) | Cold prefix cache (SSD tier didn't hit) | Use `--warm-prompts <seed.json>` for repeated workloads in the same project. |
| `claude` says it can't find `mcp__searxng__*` | MCP not registered with Claude Code | `claude mcp add searxng -- $(pwd)/run.sh` from `searxng-mcp/`. |

## Why we don't `pip install vllm-mlx`

`localclaude` resolves `PYTHONPATH=$VLLM_MLX_DIR` ahead of any system-wide vllm-mlx so the fork's source wins. Two reasons:

1. **The fork patches** (above) aren't on PyPI yet. Without them prefill is 10-20× slower.
2. **We want to track upstream `main`.** The fork is rebased onto upstream regularly; running from source means a `git pull` in `vllm-mlx/` picks up upstream fixes immediately.

The cost is one extra `pip install -e .` at setup time. The benefit is that you get the patches *and* upstream evolution.

## Why this layout instead of one repo?

- **vllm-mlx** is upstream (waybarrios/vllm-mlx) — we want to track its main branch and contribute upstream, not vendor a fork.
- **localclaude** is independently useful (anyone running vllm-mlx with Claude Code can use it without searxng-mcp or this umbrella) and changes infrequently.
- **searxng-mcp** is a generic MCP server that other people's Claude Code setups might want — it doesn't depend on vllm-mlx.
- **This umbrella** holds the cross-component things: the architectural README you're reading, the `bench/` harness that needs all three, and decisions about how they fit together.

The price is three `git clone` commands at setup. The benefit is that each component evolves at its own pace and can be used standalone.
