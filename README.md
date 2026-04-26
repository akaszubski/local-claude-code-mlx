# local-claude-code-mlx

Run **Claude Code** against a **local Qwen** model on Apple Silicon, with real
web research and an A/B benchmark harness for cache tuning. No cloud, no API
keys, no rate limits.

**Read also**: [ARCHITECTURE.md](ARCHITECTURE.md) for technical layout and request flow · [CHANGELOG.md](CHANGELOG.md) for what's in this version and why.

## What's in this umbrella

| Component | Repo | What it is |
|---|---|---|
| [`vllm-mlx/`](https://github.com/waybarrios/vllm-mlx) | upstream | The inference server. vLLM-style continuous batching + paged KV cache + prefix cache + SSD tiering on Metal. Exposes OpenAI `/v1/*` and Anthropic `/v1/messages` from one process. |
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

You only do this once per machine.

### 1. Hardware / OS prereqs

- Apple Silicon Mac (M1+). Recommended ≥32 GB RAM for `coder` profile, ≥64 GB for `coder-next` 8-bit, ≥256 GB for `coder-480`.
- macOS 14+.

### 2. Clone the umbrella + sister repos

The sister components are independent git repos — clone them as siblings of this umbrella:

```bash
mkdir -p ~/Dev/local-claude-code-mlx && cd ~/Dev/local-claude-code-mlx
git clone https://github.com/akaszubski/local-claude-code-mlx.git .
git clone https://github.com/waybarrios/vllm-mlx.git
git clone https://github.com/akaszubski/localclaude.git
git clone https://github.com/akaszubski/searxng-mcp.git
```

After this, `localclaude` (the bash script) auto-resolves all sister paths from its own location — no env vars needed unless you've moved things.

### 3. Install dependencies

```bash
# Inference server — use the local checkout (carries optimizer + thinking-gate
# patches that ship before they reach PyPI):
cd vllm-mlx && pip install -e . && cd ..

# Claude Code CLI:
brew install claude   # or however you install it

# OrbStack (provides docker engine for the SearXNG container — Docker Desktop
# also works):
brew install orbstack
orb start    # ensure the engine is up
```

### 3. Bring up SearXNG (web search backend)

```bash
cd searxng-mcp
docker compose up -d
# Verifies:
curl -sf http://127.0.0.1:8080/ >/dev/null && echo "SearXNG up"
```

Container is named `localclaude-searxng` with `restart: unless-stopped`, so it
auto-comes-back after reboots once OrbStack is running.

### 4. Register the MCP server with Claude Code

```bash
claude mcp add searxng -- $(pwd)/run.sh
```

(Run from inside `searxng-mcp/`.) Restart Claude Code; the model will now see
`mcp__searxng__search` and `mcp__searxng__fetch`.

### 5. Put `localclaude` on your PATH

```bash
echo "export PATH=$(pwd)/localclaude:\$PATH" >> ~/.zshrc
source ~/.zshrc
```

(Run from the umbrella root.)

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
