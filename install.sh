#!/usr/bin/env bash
# install.sh — one-shot setup for the local-claude-code-mlx stack.
#
# Mac-only. Brings up the full stack:
#   1. Verifies Apple Silicon + macOS
#   2. Installs missing system deps via Homebrew
#   3. Clones sister repos (vllm-mlx, localclaude, searxng-mcp)
#   4. Installs Python deps (vllm-mlx editable, searxng-mcp venv)
#   5. Starts OrbStack engine + SearXNG container
#   6. Registers searxng MCP server with Claude Code
#   7. Adds localclaude/ to your shell PATH
#   8. Runs `localclaude doctor` to verify
#
# Idempotent: safe to re-run. Skips work that's already done.
#
# Usage:
#   ./install.sh             # interactive (prompts before .zshrc edit)
#   ./install.sh --yes       # auto-confirm all prompts
#   ./install.sh --no-path   # don't touch shell rc
#   ./install.sh --no-mcp        # don't register searxng MCP with claude
#   ./install.sh --no-container  # skip OrbStack + SearXNG container (CI mode)
#   ./install.sh --dry-run       # show what would happen, change nothing

set -euo pipefail

# ── Colors and helpers ──────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi

step()    { echo "${BOLD}${BLUE}▶${RESET} ${BOLD}$*${RESET}"; }
ok()      { echo "  ${GREEN}✓${RESET} $*"; }
warn()    { echo "  ${YELLOW}⚠${RESET} $*"; }
err()     { echo "  ${RED}✗${RESET} $*" >&2; }
fatal()   { err "$*"; exit 1; }
ask()     {
    if [[ "$AUTO_YES" == "1" ]]; then return 0; fi
    local prompt="$1"
    read -r -p "  ${YELLOW}?${RESET} ${prompt} [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}
maybe()   {  # echo + execute (or just echo in dry-run)
    # Each caller passes a single shell-syntax string (so we can express
    # subshells like `(cd … && …)`). Joining with $* keeps shellcheck happy
    # on SC2294 — eval-ing $@ would negate the benefit of args arrays, but
    # we genuinely want string-eval semantics here.
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    ${DIM}\$ $*${RESET}"
    else
        eval "$*"
    fi
}

# ── Args ────────────────────────────────────────────────────────────
AUTO_YES=0
NO_PATH=0
NO_MCP=0
NO_CONTAINER=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        AUTO_YES=1; shift ;;
        --no-path)       NO_PATH=1; shift ;;
        --no-mcp)        NO_MCP=1; shift ;;
        --no-container)  NO_CONTAINER=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) fatal "unknown option: $1 (try --help)" ;;
    esac
done

# ── Paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UMBRELLA="$SCRIPT_DIR"
VLLM_MLX_DIR="$UMBRELLA/vllm-mlx"
LOCALCLAUDE_DIR="$UMBRELLA/localclaude"
SEARXNG_MCP_DIR="$UMBRELLA/searxng-mcp"

echo
echo "${BOLD}local-claude-code-mlx — install${RESET}"
echo "${DIM}umbrella: $UMBRELLA${RESET}"
[[ "$DRY_RUN" == "1" ]] && echo "${YELLOW}dry-run mode — no changes will be made${RESET}"
echo

# ── 1. Pre-flight: macOS + Apple Silicon ────────────────────────────
step "1/8  Pre-flight checks"

[[ "$(uname -s)" == "Darwin" ]] || fatal "macOS only. Detected: $(uname -s)"
ok "macOS detected"

[[ "$(uname -m)" == "arm64" ]] || fatal "Apple Silicon (arm64) required. Detected: $(uname -m)"
ok "Apple Silicon (arm64)"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
if (( macos_major < 14 )); then
    warn "macOS $macos_major detected — recommend 14+. Continuing anyway."
else
    ok "macOS $(sw_vers -productVersion)"
fi

ram_gb=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
ok "$ram_gb GB RAM"
if (( ram_gb < 32 )); then
    warn "Less than 32 GB RAM — only 'instruct' / 'qwen36' / 'gemma4' profiles likely to fit. coder/coder-next need 32+."
fi

# ── 2. System deps ──────────────────────────────────────────────────
echo
step "2/8  System dependencies"

if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not installed."
    echo "    Install it first: https://brew.sh"
    echo "    Then re-run this script."
    exit 1
fi
ok "brew $(brew --version | head -1 | awk '{print $2}')"

# Required: git
command -v git >/dev/null 2>&1 || fatal "git not found (should ship with macOS)"
ok "git $(git --version | awk '{print $3}')"

# Required: python3.10+
if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing — installing via brew"
    maybe "brew install python@3.12"
fi
py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
py_ok=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')
[[ "$py_ok" == "1" ]] || fatal "python3 $py_version too old (need 3.10+)"
ok "python3 $py_version"

# Required: claude CLI
if ! command -v claude >/dev/null 2>&1; then
    warn "claude CLI missing — installing via brew"
    maybe "brew install claude"
else
    ok "claude $(claude --version 2>&1 | head -1 | awk '{print $1}')"
fi

# Required: orbstack (provides docker engine for searxng container)
if ! command -v orb >/dev/null 2>&1; then
    warn "OrbStack missing — installing via brew (cask)"
    maybe "brew install --cask orbstack"
    warn "OrbStack installed. You may need to launch it once from Applications to complete setup."
else
    ok "orbstack on PATH"
fi

# Required: docker CLI (provided by orbstack)
if ! command -v docker >/dev/null 2>&1; then
    warn "docker CLI not on PATH — OrbStack should add it. Restart your shell after install."
else
    ok "docker on PATH"
fi

# Optional: gh (for filing issues)
if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not installed (optional, only needed if you want to file GitHub issues)"
else
    ok "gh $(gh --version | head -1 | awk '{print $3}')"
fi

# ── 3. Sister repos ─────────────────────────────────────────────────
echo
step "3/8  Sister repositories"

clone_if_missing() {
    local url="$1" dir="$2" name="$3"
    if [[ -d "$dir/.git" ]]; then
        ok "$name already cloned ($dir)"
    elif [[ -d "$dir" ]]; then
        warn "$name dir exists but is not a git repo — leaving it alone: $dir"
    else
        echo "  cloning $name…"
        maybe "git clone --depth 1 '$url' '$dir'"
        ok "$name cloned"
    fi
}

# vllm-mlx: clone the AKASZUBSKI FORK, not upstream waybarrios. The fork
# carries the prompt optimizer, tool-stubbing, and thinking-gate patches
# (commits 818f3fcb / b680dc20 / ae25fb83). Without these, prefill of an
# 80K-token Claude Code request is ~50s instead of ~3-5s — unusable.
# The fork tracks upstream and rebases regularly; we file bugs upstream
# at waybarrios/vllm-mlx but install from the fork.
clone_if_missing https://github.com/akaszubski/vllm-mlx.git    "$VLLM_MLX_DIR"    "vllm-mlx (fork — required for optimizer patches)"
clone_if_missing https://github.com/akaszubski/localclaude.git "$LOCALCLAUDE_DIR" localclaude
clone_if_missing https://github.com/akaszubski/searxng-mcp.git "$SEARXNG_MCP_DIR" searxng-mcp

# ── 4. Python deps ──────────────────────────────────────────────────
echo
step "4/8  Python dependencies"

# vllm-mlx: install editable so the fork patches win + deps are pulled
if python3 -c "import vllm_mlx" 2>/dev/null && [[ "$(python3 -c 'import vllm_mlx, os; print(os.path.dirname(vllm_mlx.__file__))')" == "$VLLM_MLX_DIR/vllm_mlx" ]]; then
    ok "vllm-mlx already installed editable from $VLLM_MLX_DIR"
else
    echo "  installing vllm-mlx editable from local source (this pulls deps and may take a few minutes)…"
    maybe "python3 -m pip install --quiet -e '$VLLM_MLX_DIR'"
    ok "vllm-mlx installed editable"
fi

# searxng-mcp: dedicated venv for MCP runtime
if [[ -x "$SEARXNG_MCP_DIR/.venv/bin/python" ]] && "$SEARXNG_MCP_DIR/.venv/bin/python" -c "import mcp, httpx" 2>/dev/null; then
    ok "searxng-mcp venv ready ($SEARXNG_MCP_DIR/.venv)"
else
    echo "  creating searxng-mcp venv + installing mcp + httpx…"
    maybe "python3 -m venv '$SEARXNG_MCP_DIR/.venv'"
    maybe "'$SEARXNG_MCP_DIR/.venv/bin/pip' install --quiet mcp httpx"
    ok "searxng-mcp venv created"
fi

# ── 5. SearXNG container ────────────────────────────────────────────
echo
step "5/8  SearXNG container"

if [[ "$NO_CONTAINER" == "1" ]]; then
    warn "skipped (--no-container)"
elif ! docker info >/dev/null 2>&1; then
    if command -v orb >/dev/null 2>&1; then
        echo "  starting OrbStack engine…"
        maybe "orb start"
        sleep 3
        if ! docker info >/dev/null 2>&1; then
            warn "OrbStack engine still not responding. Try launching OrbStack.app once, then re-run this script."
        else
            ok "OrbStack engine up"
        fi
    else
        warn "Docker daemon not running and orb command unavailable. Skipping container bring-up."
    fi
else
    ok "Docker daemon responding"
fi

# Container
if [[ "$NO_CONTAINER" != "1" ]] && docker info >/dev/null 2>&1; then
    cstate=$(docker inspect -f '{{.State.Status}}' localclaude-searxng 2>/dev/null || echo "missing")
    case "$cstate" in
        running)
            ok "localclaude-searxng container already running"
            ;;
        missing)
            echo "  bringing up localclaude-searxng container…"
            maybe "(cd '$SEARXNG_MCP_DIR' && docker compose up -d)"
            ok "container created"
            ;;
        exited|created|dead)
            warn "localclaude-searxng exists but is in state '$cstate' — recreating"
            maybe "docker rm -f localclaude-searxng"
            maybe "(cd '$SEARXNG_MCP_DIR' && docker compose up -d)"
            ok "container recreated"
            ;;
        *)
            warn "container in unexpected state '$cstate' — leaving alone"
            ;;
    esac

    # Wait for SearXNG to respond on :8080
    if [[ "$DRY_RUN" != "1" ]]; then
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if curl -sf -o /dev/null -m 2 http://127.0.0.1:8080/ 2>/dev/null; then
                ok "SearXNG responding on http://127.0.0.1:8080"
                break
            fi
            [[ $i -eq 1 ]] && echo -n "  waiting for SearXNG"
            echo -n "."
            sleep 2
        done
        echo
    fi
fi

# ── 6. MCP registration ─────────────────────────────────────────────
echo
step "6/8  Register searxng MCP with Claude Code"

if [[ "$NO_MCP" == "1" ]]; then
    warn "skipped (--no-mcp)"
elif ! command -v claude >/dev/null 2>&1; then
    warn "claude CLI missing — skipping MCP registration"
elif claude mcp list 2>/dev/null | grep -qi searxng; then
    ok "searxng MCP already registered"
else
    if ask "Register searxng MCP server (\`mcp__searxng__*\` tools) with Claude Code now?"; then
        maybe "claude mcp add searxng -- '$SEARXNG_MCP_DIR/run.sh'"
        ok "searxng MCP registered"
    else
        warn "skipped — register later with:"
        echo "    claude mcp add searxng -- $SEARXNG_MCP_DIR/run.sh"
    fi
fi

# ── 7. Shell PATH ───────────────────────────────────────────────────
echo
step "7/8  Add localclaude to your shell PATH"

if [[ "$NO_PATH" == "1" ]]; then
    warn "skipped (--no-path)"
elif command -v localclaude >/dev/null 2>&1 && [[ "$(command -v localclaude)" == "$LOCALCLAUDE_DIR/localclaude" ]]; then
    ok "localclaude already on PATH from $LOCALCLAUDE_DIR"
else
    # Detect the user's shell rc
    case "$SHELL" in
        */zsh)  rc="$HOME/.zshrc" ;;
        */bash) rc="$HOME/.bashrc" ;;
        *)      rc="" ;;
    esac

    if [[ -z "$rc" ]]; then
        warn "Unrecognised shell ($SHELL) — add this to your shell rc manually:"
        echo "    export PATH=\"$LOCALCLAUDE_DIR:\$PATH\""
    elif grep -qF "$LOCALCLAUDE_DIR" "$rc" 2>/dev/null; then
        ok "$rc already references $LOCALCLAUDE_DIR"
    elif ask "Append PATH export for $LOCALCLAUDE_DIR to $rc?"; then
        maybe "echo '' >> '$rc'"
        maybe "echo '# local-claude-code-mlx' >> '$rc'"
        maybe "echo 'export PATH=\"$LOCALCLAUDE_DIR:\$PATH\"' >> '$rc'"
        ok "added to $rc — open a new shell or run: source $rc"
    else
        warn "skipped — add this to $rc when ready:"
        echo "    export PATH=\"$LOCALCLAUDE_DIR:\$PATH\""
    fi
fi

# ── 8. Verify ───────────────────────────────────────────────────────
echo
step "8/8  Verify"

if [[ -x "$LOCALCLAUDE_DIR/localclaude" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    ${DIM}\$ $LOCALCLAUDE_DIR/localclaude doctor${RESET}"
    else
        echo
        "$LOCALCLAUDE_DIR/localclaude" doctor || true
    fi
else
    warn "localclaude script not executable: $LOCALCLAUDE_DIR/localclaude"
fi

# ── Done ────────────────────────────────────────────────────────────
echo
echo "${BOLD}${GREEN}✓ Install complete.${RESET}"
echo
echo "Next steps:"
echo "  1. ${BOLD}Open a new terminal${RESET} (or \`source ~/.zshrc\`) so localclaude is on PATH."
echo "  2. From any project directory, run: ${BOLD}localclaude start coder${RESET}"
echo "  3. In a second terminal: ${BOLD}localclaude cc${RESET} (launches claude with the right env)"
echo
echo "Read the umbrella README and ARCHITECTURE.md for performance tuning,"
echo "the operational caveats (security posture, memory leak watchdog), and"
echo "the bench harness for cache-config A/B testing."
echo
echo "${BOLD}Recommended (optional):${RESET} append the search-routing snippet to your"
echo "global ~/.claude/CLAUDE.md so the model goes straight to mcp__searxng__*"
echo "for web research. ~15 lines. See README.md → \"Recommended ~/.claude/CLAUDE.md"
echo "snippet (nice-to-have)\". This script does NOT auto-edit your CLAUDE.md;"
echo "that file is too important to mutate without you reading the snippet first."
