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

## Do NOT

- ❌ **Run `pip install vllm-mlx`** from PyPI. The local checkout (`vllm-mlx/`) carries fork patches that aren't on PyPI yet — the prompt optimizer (`818f3fcb`), tool stubs, and thinking-gate. Without them, prefill of an 80K-token Claude Code request takes ~50 s instead of ~3 s. The install script handles `pip install -e ./vllm-mlx` correctly; don't override it.
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
