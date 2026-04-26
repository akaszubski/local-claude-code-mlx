# local-claude-code-mlx

Run **Claude Code** against a **local Qwen** model on Apple Silicon, with real
web research and an A/B benchmark harness for cache tuning. No cloud, no API
keys, no rate limits.

## What's in this umbrella

| Component | What it is |
|---|---|
| [`vllm-mlx/`](vllm-mlx/) | The inference server. vLLM-style continuous batching + paged KV cache + prefix cache + SSD tiering on Metal. Exposes OpenAI `/v1/*` and Anthropic `/v1/messages` from one process. |
| [`localclaude/`](localclaude/) | Single-command lifecycle wrapper. Boots `vllm-mlx` with the right model + tool parser per profile, prints the `claude` connect command, manages stop/restart/status. |
| [`searxng-mcp/`](searxng-mcp/) | Tiny MCP server that gives Claude Code a `mcp__searxng__search` tool backed by a local SearXNG container. Replaces Anthropic's server-side `WebSearch` (which no-ops against local LLMs). |
| [`bench/`](bench/) | A/B harness that measures wall-clock + TTFT under realistic Claude Code traffic across four cache configurations (baseline / `--warm-prompts` / `+--ssd-cache-dir` / `+--kv-cache-quantization`). |

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

- Apple Silicon Mac (M1+). Recommended ≥32 GB RAM for `coder` profile, ≥64 GB for `coder-next` 8-bit.
- macOS 14+.

### 2. Install dependencies

```bash
# Inference server (PyPI):
pip install vllm-mlx
# Or use the source checkout in this repo (carries optimizer + thinking-gate
# patches that ship before they reach PyPI):
cd vllm-mlx && pip install -e . && cd ..

# Claude Code CLI:
brew install claude   # or however you install it

# OrbStack (provides docker engine for the SearXNG container — Docker Desktop
# also works):
brew install orbstack
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

## Performance tuning (the 3 cache knobs)

`vllm-mlx` ships three cache optimizations that aren't on by default in
`localclaude` profiles:

| Knob | Flag | What it buys you |
|---|---|---|
| Warm-prompts seeding | `--warm-prompts <seed.json>` | Removes the 30s "first prompt" prefill stall by pre-warming the prefix cache at startup |
| SSD cache tiering | `--ssd-cache-dir <path>` | Persists prefix cache to disk; cold restarts reuse it |
| 8-bit KV quantization | `--kv-cache-quantization --kv-cache-quantization-bits 8` | Halves KV memory pressure; lets the cache hold more context |

Enable any/all of them via the bench escape hatch:

```bash
LOCALCLAUDE_EXTRA_VLLM_ARGS="--ssd-cache-dir ~/.localclaude/ssd-cache --kv-cache-quantization --kv-cache-quantization-bits 8" \
  localclaude start coder
```

To benchmark them empirically before flipping defaults:

```bash
bench/run.sh                # full A/B/C/D matrix
bench/run.sh --smoke        # ~90s sanity
```

See [`bench/README.md`](bench/README.md) for harness details.

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
