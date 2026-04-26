# AGENTS.md

Instructions for AI agents installing or modifying this repo.

## Installing

If you are setting this stack up on the user's behalf:

```bash
git clone https://github.com/akaszubski/local-claude-code-mlx.git ~/Dev/local-claude-code-mlx
cd ~/Dev/local-claude-code-mlx
./install.sh
```

That's it. The script is Mac-only (Apple Silicon), idempotent, and walks the user through 8 phases including dep installation, sister-repo cloning, container setup, and verification. `./install.sh --help` for flags.

After it finishes, verify with: `localclaude doctor`.

If the user wants the model to confidently route web-research requests to `mcp__searxng__*` (vs inferring it from a missing `WebSearch` tool), point them at the README's "Recommended `~/.claude/CLAUDE.md` snippet" section. **Do NOT auto-edit `~/.claude/CLAUDE.md`** — it's the user's persistent, all-projects file and they should review the snippet before adding it.

## Model storage

This stack uses **`~/Models/`** as the canonical HuggingFace cache, not the upstream `~/.cache/huggingface/hub/` default. The user sets `HF_HUB_CACHE=$HOME/Models` in their shell rc once. `localclaude` reads both locations (`_is_model_cached()` at `localclaude:342`) so legacy installs keep working during migration.

When helping the user with model storage:

- ✅ **Recommend `~/Models/`** as the cache location.
- ✅ **Suggest setting `HF_HUB_CACHE=$HOME/Models`** in `~/.zshrc` if not already set.
- ❌ **Do NOT automatically migrate** existing models from `~/.cache/huggingface/hub/` to `~/Models/` without showing the user the diff first (`mv` is fast but not free, and the user may have models in both places intentionally).
- ❌ **Do NOT use `~/.cache/huggingface/hub/`** in install instructions.

## Single-Mac vs multi-Mac

The default install is **single-Mac**. Everything multi-Mac (NFS-shared `~/Models/`, `LOCALCLAUDE_CODER_480_REMOTE`, SSH dispatch for `coder-480`) is **opt-in**.

When helping a user install or configure:

- **Default to single-Mac behaviour** unless the user explicitly mentions a second Mac.
- **Don't suggest NFS setup** unsolicited. It's documented in the README's "(Optional) Multi-Mac setups" section but not appropriate for a fresh install.
- **`coder-480` profile**: only useful if the user has ≥256 GB of RAM (M3 Ultra-class) OR has a remote Mac that does. Don't suggest `coder-480` to a 16/32/64 GB Mac user — they should use `coder` (~17 GB), `coder-next` (~32 GB), or `qwen36` (~20 GB) instead.
- **`LOCALCLAUDE_NO_REMOTE=1`**: tell the user about this if they're worried about accidental SSH egress from their Mac. It hard-disables remote dispatch.

## Do NOT

- ❌ **Run `pip install vllm-mlx`** from PyPI. The required source is the [`akaszubski/vllm-mlx`](https://github.com/akaszubski/vllm-mlx) fork (not upstream `waybarrios/vllm-mlx`, not PyPI). The fork carries the prompt optimizer (`818f3fcb`), tool stubs (`ae25fb83`), and thinking-gate (`b680dc20`) patches. Without them, prefill of an 80K-token Claude Code request takes ~50 s instead of ~3 s — the local stack is unusable. The install script clones the fork and runs `pip install -e ./vllm-mlx`; don't override either part.
- ❌ **Clone `waybarrios/vllm-mlx`** for the install. That's upstream — no patches. Only use it as the destination for bug reports.
- ❌ **Try this on Linux or Intel Mac.** Apple Silicon + macOS only. The script bails clearly; don't try to "patch around" the bail.
- ❌ **Skip the SearXNG container.** Without it, `mcp__searxng__*` tools fail and Claude Code falls back to no-op `WebSearch`. The default `code` allowlist references searxng MCP — disabling it without also changing the allowlist will leave the model trying to call missing tools.
- ❌ **Improvise dependency versions.** Use what's pinned in the sister repos' setup files. If something seems wrong, file an issue rather than patching.
- ❌ **`brew install vllm-mlx`** — there's no such formula; vllm-mlx is a Python package only.

## Modifying

If you're making changes to anything in this umbrella:

- The umbrella ships `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md`, `LICENSE`, `install.sh`, `AGENTS.md`, and the `bench/` harness. Sister components live in their own repos (`vllm-mlx`, `localclaude`, `searxng-mcp`) — don't try to vendor them.
- `bench/cases/seed.warm.json` is **gitignored** because it's a captured Claude Code request containing personal CLAUDE.md / paths / MCP inventory. Regenerate per machine via `bench/capture_seed.py capture-start`.
- Pre-commit there are no hooks in this repo, but watch out for: literal `/Users/<name>/` paths, anything starting with `# claudeMd` in fixtures, and `.localclaude/` artefacts.
- Architectural decisions live in `CHANGELOG.md` "Decisions (with reasoning)" — add an entry there when you change a default or land a new perf knob.

## Verifying your work

- Static check the install script: `bash -n install.sh && shellcheck install.sh`
- Dry run: `./install.sh --dry-run`
- After install: `localclaude doctor` — all required deps green, container responding, MCP registered.
- For perf changes: `bench/run.sh --smoke` (~90 s) at minimum; full `bench/run.sh` for anything touching the cache layer.

## Context windows

The user's `~/.claude/CLAUDE.md` and per-project `./CLAUDE.md` are embedded in every Claude Code request and contribute directly to prefill cost. Don't bloat them. See README.md "Keep your CLAUDE.md files lean" for the guidance.

## Filing issues

- For bugs in this umbrella: https://github.com/akaszubski/local-claude-code-mlx/issues
- For inference-server bugs: https://github.com/waybarrios/vllm-mlx/issues (issues enabled there; not on the fork)
- For lifecycle/wrapper bugs: https://github.com/akaszubski/localclaude/issues
- For MCP server bugs: https://github.com/akaszubski/searxng-mcp/issues

Use `gh issue create` only after duplicate-checking the existing open issues.
