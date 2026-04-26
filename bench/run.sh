#!/usr/bin/env bash
# bench/run.sh — A/B-test vllm-mlx cache flags across cases A,B,C,D × 1..5.
# See bench/README.md for usage.

set -euo pipefail

# ── Workspace resolution (mirrors localclaude pattern) ───────────────
_resolve_bench_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local link
        link="$(readlink "$src")"
        [[ "$link" = /* ]] && src="$link" || src="$(dirname "$src")/$link"
    done
    cd "$(dirname "$src")" && pwd
}
BENCH_DIR="$(_resolve_bench_dir)"
WORKSPACE_DIR="$(dirname "$BENCH_DIR")"
CASES_DIR="$BENCH_DIR/cases"
LIB_DIR="$BENCH_DIR/lib"
SEED_PATH="$CASES_DIR/seed.warm.json"
LOCALCLAUDE="$WORKSPACE_DIR/localclaude/localclaude"
ACTIVE_FILE="$HOME/.localclaude/.active"
LIVE_LOG_DIR="$HOME/.localclaude/logs"

# shellcheck source=lib/log_offset.sh
source "$LIB_DIR/log_offset.sh"

# ── Defaults ─────────────────────────────────────────────────────────
PROFILE="coder"
CONDITIONS_CSV="A,B,C,D"
CASES_CSV="1,2,3,4,5"
TRIALS=5
NO_POST_RESTART=0
DRY_RUN=0
SMOKE=0
PER_REQUEST_TIMEOUT=120
OUT_DIR=""
NO_SERVER_BOUNCE=0   # internal: assume server already up; for dev only

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --profile <name>          localclaude profile (default: coder)
  --conditions <CSV>        any of A,B,C,D,E (default: A,B,C,D)
                              E adds --enable-mtp; only useful on profiles
                              whose model has MTP weights (Qwen3-Next family,
                              Qwen3.5/3.6). On other profiles vllm-mlx
                              auto-disables MTP and E collapses to D.
  --cases <CSV>             any of 1,2,3,4,5 (default: 1,2,3,4,5)
  --trials <N>              trials per (condition,case) (default: 5)
  --no-post-restart         skip case 5 (post-restart probe)
  --dry-run                 print plan, exit 0, touch nothing
  --smoke                   --conditions A --cases 1 --trials 1 (<90s)
  --timeout <sec>           per-request timeout (default: 120)
  --out-dir <path>          run output dir (default: bench/runs/<ts>)
  --no-server-bounce        assume an externally-running server (dev)
  -h, --help                this help
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --conditions) CONDITIONS_CSV="$2"; shift 2 ;;
        --cases) CASES_CSV="$2"; shift 2 ;;
        --trials) TRIALS="$2"; shift 2 ;;
        --no-post-restart) NO_POST_RESTART=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --smoke) SMOKE=1; shift ;;
        --timeout) PER_REQUEST_TIMEOUT="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --no-server-bounce) NO_SERVER_BOUNCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$SMOKE" -eq 1 ]]; then
    CONDITIONS_CSV="A"
    CASES_CSV="1"
    TRIALS=1
fi

LIVE_LOG="$LIVE_LOG_DIR/$PROFILE.log"

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$BENCH_DIR/runs/$(date +%Y%m%d-%H%M%S)"
fi
OUT_DIR="$(cd "$(dirname "$OUT_DIR")" 2>/dev/null && pwd || true)/$(basename "$OUT_DIR")"
# fallback if parent didn't exist yet
if [[ ! "$OUT_DIR" = /* ]]; then
    OUT_DIR="$BENCH_DIR/runs/$(basename "$OUT_DIR")"
fi

IFS=',' read -r -a CONDITIONS <<<"$CONDITIONS_CSV"
IFS=',' read -r -a CASES <<<"$CASES_CSV"

RUN_ID="$(basename "$OUT_DIR")"

# ── Condition flag builder (lazy: needs OUT_DIR resolved) ────────────
extra_args_for() {
    local cond="$1"
    case "$cond" in
        A) echo "" ;;
        B) echo "--warm-prompts $SEED_PATH" ;;
        C) echo "--warm-prompts $SEED_PATH --ssd-cache-dir $OUT_DIR/.ssdcache" ;;
        D) echo "--warm-prompts $SEED_PATH --ssd-cache-dir $OUT_DIR/.ssdcache --kv-cache-quantization --kv-cache-quantization-bits 8" ;;
        E) echo "--warm-prompts $SEED_PATH --ssd-cache-dir $OUT_DIR/.ssdcache --kv-cache-quantization --kv-cache-quantization-bits 8 --enable-mtp" ;;
        *) echo "" ;;
    esac
}

# ── Seed validation gate ─────────────────────────────────────────────
needs_seed() {
    for c in "${CONDITIONS[@]}"; do
        case "$c" in B|C|D) return 0 ;; esac
    done
    return 1
}

validate_seed() {
    if [[ ! -f "$SEED_PATH" ]]; then
        cat >&2 <<EOF
ERROR: warm-prompts seed not found at:
  $SEED_PATH

Run Step 0 first to capture a real Claude Code request:
  python3 $BENCH_DIR/capture_seed.py capture-start
  # (in another terminal) trigger one realistic claude --print request
  # then Ctrl-C the proxy and convert:
  python3 $BENCH_DIR/capture_seed.py seed-from-capture \\
      --in $BENCH_DIR/cases/_capture/req.json \\
      --out $SEED_PATH
EOF
        exit 3
    fi
    local size first_content_len
    size=$(log_size "$SEED_PATH")
    first_content_len=$(python3 - "$SEED_PATH" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
try:
    msgs = data[0]
    content = msgs[0].get("content", "")
    print(len(content) if isinstance(content, str) else len(json.dumps(content)))
except Exception:
    print(0)
PY
)
    if (( size <= 5000 )) && (( first_content_len <= 4000 )); then
        cat >&2 <<EOF
ERROR: seed file looks like the toy placeholder.
  $SEED_PATH
  on-disk size = $size bytes (need > 5000)
  first-message content len = $first_content_len chars (need > 4000)

Re-run Step 0 (bench/capture_seed.py) against a real Claude Code session.
EOF
        exit 4
    fi
}

# ── Active model lookup ──────────────────────────────────────────────
read_active_model() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        awk -F= '$1=="model"{print $2}' "$ACTIVE_FILE" | head -1
    else
        echo ""
    fi
}

# ── Server lifecycle ─────────────────────────────────────────────────
SERVER_LOG=""
CURRENT_CONDITION=""
CURRENT_CASE=""
CURRENT_TRIAL=""
ABORTED=0
TRIAL_IN_PROGRESS=0

server_messages_alive_py() {
    local body_path="$CASES_DIR/01_curl_hello.json"
    [[ -f "$body_path" ]] || return 1
    [[ -n "${ACTIVE_MODEL:-}" ]] || return 1
    PYBODY="$body_path" PYMODEL="$ACTIVE_MODEL" python3 - <<'PY' >/dev/null 2>&1
import json, os, urllib.request, urllib.error
spec = json.loads(open(os.environ["PYBODY"]).read())
b = dict(spec["body"])
if b.get("model") == "PROFILE_MODEL":
    b["model"] = os.environ["PYMODEL"]
b["max_tokens"] = 1
data = json.dumps(b).encode()
req = urllib.request.Request(
    "http://127.0.0.1:8000/v1/messages",
    data=data,
    headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=2) as r:
        if 200 <= r.status < 300:
            raise SystemExit(0)
        raise SystemExit(1)
except urllib.error.HTTPError:
    raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PY
}

start_server_for() {
    local cond="$1"
    local extra
    extra="$(extra_args_for "$cond")"
    SERVER_LOG="$OUT_DIR/${cond}.server.log"
    : > "$SERVER_LOG"
    local start_log="$OUT_DIR/${cond}.start.log"
    : > "$start_log"

    if [[ "$NO_SERVER_BOUNCE" -eq 1 ]]; then
        if server_messages_alive_py; then
            echo "[bounce-skipped] using externally-running server (cond=$cond)"
            return 0
        fi
        echo "ERROR: --no-server-bounce set but no responsive server on :8000" >&2
        return 1
    fi

    echo "[start] condition=$cond extra='$extra'"
    LOCALCLAUDE_EXTRA_VLLM_ARGS="$extra" "$LOCALCLAUDE" start "$PROFILE" >>"$start_log" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "[start-failed] condition=$cond (localclaude exit=$rc)" >&2
        return 1
    fi
    # Refresh ACTIVE_MODEL: localclaude stop deletes ~/.localclaude/.active,
    # so the early read at script-init returned the "unknown-model" fallback.
    # Probes built with that fallback are 404'd by vllm-mlx as model-mismatch.
    local refreshed
    refreshed="$(read_active_model)"
    [[ -n "$refreshed" ]] && ACTIVE_MODEL="$refreshed"
    local deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
        if server_messages_alive_py; then
            echo "[ready] condition=$cond"
            return 0
        fi
        sleep 1
    done
    echo "[start-failed] condition=$cond (router-not-ready after localclaude returned)" >&2
    return 1
}

stop_server() {
    if [[ "$NO_SERVER_BOUNCE" -eq 1 ]]; then
        return 0
    fi
    "$LOCALCLAUDE" stop >/dev/null 2>&1 || true
}

# ── Per-case execution ───────────────────────────────────────────────
run_case_curl() {
    local model="$1" out_json="$2"
    local body_path="$CASES_DIR/01_curl_hello.json"
    PYBODY="$body_path" PYMODEL="$model" PYTIMEOUT="$PER_REQUEST_TIMEOUT" \
        python3 - <<'PY' >"$out_json"
import json, os, sys, time, urllib.request, urllib.error
body_path = os.environ["PYBODY"]
model = os.environ["PYMODEL"]
timeout = float(os.environ["PYTIMEOUT"])
spec = json.loads(open(body_path).read())
body = dict(spec["body"])
if body.get("model") == "PROFILE_MODEL":
    body["model"] = model
data = json.dumps(body).encode("utf-8")
req = urllib.request.Request(
    "http://127.0.0.1:8000/v1/messages",
    data=data,
    headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
    method="POST",
)
out = {"status": "ok", "wall_ms": None, "duration_ms": None,
       "num_turns": 1, "stdout_chars": 0, "http_status": None}
t0 = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        text = resp.read().decode("utf-8", errors="replace")
        out["http_status"] = resp.status
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    out["duration_ms"] = out["wall_ms"]
    out["stdout_chars"] = len(text)
    if resp.status >= 500:
        out["status"] = "http_500"
        out["error_class"] = "http_500"
    elif resp.status >= 400:
        out["status"] = "http_500"  # treat as failure class
        out["error_class"] = "http_500"
except urllib.error.URLError as e:
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    msg = str(e.reason if hasattr(e, "reason") else e)
    if "refused" in msg.lower():
        out["status"] = "connect_refused"
        out["error_class"] = "connect_refused"
    elif "timed out" in msg.lower() or "timeout" in msg.lower():
        out["status"] = "timeout"
        out["error_class"] = "timeout"
    else:
        out["status"] = "http_500"
        out["error_class"] = "http_500"
    out["error_message"] = msg
except Exception as e:
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    out["status"] = "http_500"
    out["error_class"] = "http_500"
    out["error_message"] = f"{type(e).__name__}: {e}"
sys.stdout.write(json.dumps(out))
PY
}

run_case_cc() {
    local prompt_file="$1" model="$2" out_json="$3"
    local prompt
    prompt="$(cat "$prompt_file")"
    # Run claude --print with timeout. Capture stdout as JSON; on non-zero, classify.
    PYPROMPT="$prompt" PYMODEL="$model" PYTIMEOUT="$PER_REQUEST_TIMEOUT" \
    PYWORKSPACE="$WORKSPACE_DIR" \
        python3 - <<'PY' >"$out_json"
import json, os, subprocess, sys, time
prompt = os.environ["PYPROMPT"]
model = os.environ["PYMODEL"]
timeout = float(os.environ["PYTIMEOUT"])
cwd = os.environ["PYWORKSPACE"]
env = dict(os.environ)
env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8000"
env["ANTHROPIC_API_KEY"] = "not-needed"
env["ANTHROPIC_MODEL"] = model
env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "262144"
out = {"status": "ok", "wall_ms": None, "duration_ms": None,
       "num_turns": None, "stdout_chars": 0, "http_status": None}
t0 = time.monotonic()
try:
    proc = subprocess.run(
        ["claude", "--print", "--output-format", "json", prompt],
        cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
    )
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    out["stdout_chars"] = len(proc.stdout)
    if proc.returncode != 0:
        out["status"] = "http_500"
        out["error_class"] = "http_500"
        # Claude Code exits non-zero with the error JSON on stdout (stderr is
        # often empty). Capture both, truncated, so the run is diagnosable.
        err_parts = []
        if proc.stderr:
            err_parts.append("stderr=" + proc.stderr[-300:])
        if proc.stdout:
            err_parts.append("stdout=" + proc.stdout[-700:])
        out["error_message"] = " | ".join(err_parts) if err_parts else "(no output)"
        out["returncode"] = proc.returncode
    else:
        try:
            parsed = json.loads(proc.stdout)
            result = parsed.get("result", "")
            out["num_turns"] = parsed.get("num_turns")
            usage = parsed.get("usage") or {}
            out["output_tokens"] = usage.get("output_tokens")
            out["duration_ms"] = parsed.get("duration_ms") or out["wall_ms"]
            if not result or not str(result).strip():
                out["status"] = "empty_result"
                out["error_class"] = "empty_result"
        except Exception as e:
            out["status"] = "http_500"
            out["error_class"] = "http_500"
            out["error_message"] = f"json-parse: {e}"
except subprocess.TimeoutExpired:
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    out["status"] = "timeout"
    out["error_class"] = "timeout"
except FileNotFoundError as e:
    out["wall_ms"] = int((time.monotonic() - t0) * 1000)
    out["status"] = "http_500"
    out["error_class"] = "http_500"
    out["error_message"] = f"claude binary not found: {e}"
sys.stdout.write(json.dumps(out))
PY
}

# ── Record writer ────────────────────────────────────────────────────
write_record() {
    local json_line="$1"
    printf '%s\n' "$json_line" >>"$OUT_DIR/raw.jsonl"
}

# Resolve case spec by index (1..5).
case_spec() {
    local idx="$1"
    case "$idx" in
        1) echo "curl 01_curl_hello.json 01_curl_hello" ;;
        2) echo "cc   02_cc_list_files.txt 02_cc_list_files" ;;
        3) echo "cc   03_cc_explain_readme.txt 03_cc_explain_readme" ;;
        4) echo "cc   04_cc_multiturn.txt 04_cc_multiturn" ;;
        5) echo "post-restart 02_cc_list_files.txt 05_post_restart" ;;
        *) echo "" ;;
    esac
}

# Compose one record JSON line from the per-case Python output + timing.
compose_record() {
    local cond="$1" case_id="$2" trial="$3" started_at="$4"
    local pre="$5" post="$6" boot_offset="$7" case_out="$8"
    local extra_kv="${9:-}"
    PY_COND="$cond" PY_CASE="$case_id" PY_TRIAL="$trial" PY_STARTED="$started_at" \
    PY_PRE="$pre" PY_POST="$post" PY_BOOT="$boot_offset" PY_OUT="$case_out" \
    PY_EXTRA="$extra_kv" \
        python3 <<'PY'
import json, os
out = json.loads(os.environ["PY_OUT"])
pre = int(os.environ["PY_PRE"])
post = int(os.environ["PY_POST"])
record = {
    "condition": os.environ["PY_COND"],
    "case": os.environ["PY_CASE"],
    "trial": int(os.environ["PY_TRIAL"]),
    "status": out.get("status", "ok"),
    "wall_ms": out.get("wall_ms"),
    "duration_ms": out.get("duration_ms"),
    "num_turns": out.get("num_turns"),
    "stdout_chars": out.get("stdout_chars", 0),
    "log_offset_pre": pre,
    "log_offset_post": post,
    "boot_offset": int(os.environ["PY_BOOT"]),
    "started_at": os.environ["PY_STARTED"],
}
if post < pre:
    record["log_offset_pre"] = None
    record["log_offset_post"] = None
    record["log_rotated"] = True
if "error_class" in out:
    record["error_class"] = out["error_class"]
if "error_message" in out:
    record["error_message"] = out["error_message"]
if "output_tokens" in out:
    record["output_tokens"] = out["output_tokens"]
extra = os.environ.get("PY_EXTRA", "")
if extra:
    for kv in extra.split(";"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            try:
                v = int(v)
            except ValueError:
                pass
            record[k] = v
print(json.dumps(record))
PY
}

# ── Trap ─────────────────────────────────────────────────────────────
on_interrupt() {
    ABORTED=1
    if [[ "$TRIAL_IN_PROGRESS" -eq 1 && -n "$CURRENT_CONDITION" ]]; then
        local rec
        rec=$(python3 - <<PY
import json
print(json.dumps({
    "condition": "$CURRENT_CONDITION",
    "case": "$CURRENT_CASE",
    "trial": int("$CURRENT_TRIAL" or 0),
    "status": "aborted",
    "error_class": "aborted",
}))
PY
)
        write_record "$rec"
    fi
    stop_server
    cp "$OUT_DIR/manifest.json" "$OUT_DIR/manifest.json.aborted" 2>/dev/null || true
    echo "[aborted] SIGINT received; partial results in $OUT_DIR" >&2
    exit 130
}
trap on_interrupt INT TERM

# ── Plan / dry-run ───────────────────────────────────────────────────
print_plan() {
    echo "Bench plan"
    echo "  profile:    $PROFILE"
    echo "  conditions: ${CONDITIONS[*]}"
    echo "  cases:      ${CASES[*]}"
    echo "  trials:     $TRIALS"
    echo "  timeout:    ${PER_REQUEST_TIMEOUT}s"
    echo "  no-post-restart: $NO_POST_RESTART"
    echo "  out-dir:    $OUT_DIR"
    echo "  seed:       $SEED_PATH"
    echo
    echo "Matrix (condition × case × trial):"
    for cond in "${CONDITIONS[@]}"; do
        local extra
        extra="$(extra_args_for "$cond")"
        echo "  [$cond] EXTRA_VLLM_ARGS='$extra'"
        for c in "${CASES[@]}"; do
            local spec
            spec="$(case_spec "$c")"
            if [[ -z "$spec" ]]; then
                echo "    case $c: <unknown>"
                continue
            fi
            local kind file id
            kind=$(echo "$spec" | awk '{print $1}')
            file=$(echo "$spec" | awk '{print $2}')
            id=$(echo "$spec" | awk '{print $3}')
            if [[ "$c" == "5" ]]; then
                if [[ "$NO_POST_RESTART" -eq 1 ]]; then
                    echo "    case 5: SKIPPED (--no-post-restart)"
                    continue
                fi
                case "$cond" in
                    C|D) echo "    case 5 ($id): post-restart probe via $file (1 trial)" ;;
                    *)   echo "    case 5: skipped for condition $cond (only C,D)" ;;
                esac
            else
                echo "    case $c ($id): $kind via $file × $TRIALS trials"
            fi
        done
    done
}

if [[ "$DRY_RUN" -eq 1 ]]; then
    print_plan
    exit 0
fi

# Validate seed BEFORE creating output dirs / starting servers.
if needs_seed; then
    validate_seed
fi

mkdir -p "$OUT_DIR"
: > "$OUT_DIR/raw.jsonl"

ACTIVE_MODEL="$(read_active_model)"
if [[ -z "$ACTIVE_MODEL" ]]; then
    ACTIVE_MODEL="unknown-model"
fi

# Manifest
python3 - <<PY > "$OUT_DIR/manifest.json"
import json, os, time
print(json.dumps({
    "run_id": "$RUN_ID",
    "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "profile": "$PROFILE",
    "active_model": "$ACTIVE_MODEL",
    "conditions": "$CONDITIONS_CSV".split(","),
    "cases": "$CASES_CSV".split(","),
    "trials": int("$TRIALS"),
    "no_post_restart": bool(int("$NO_POST_RESTART")),
    "per_request_timeout_sec": int("$PER_REQUEST_TIMEOUT"),
    "smoke": bool(int("$SMOKE")),
    "out_dir": "$OUT_DIR",
    "seed_path": "$SEED_PATH",
    "host_uname": os.uname().sysname + " " + os.uname().release,
}, indent=2))
PY

print_plan
echo

# ── Main loop ────────────────────────────────────────────────────────
for COND in "${CONDITIONS[@]}"; do
    CURRENT_CONDITION="$COND"
    if ! start_server_for "$COND"; then
        rec=$(python3 - <<PY
import json
print(json.dumps({
    "condition": "$COND",
    "case": "(server-start)",
    "trial": 0,
    "status": "server-start-failed",
    "error_class": "server-start-failed",
}))
PY
)
        write_record "$rec"
        continue
    fi

    BOOT_OFFSET=$(log_size "$LIVE_LOG")

    for C in "${CASES[@]}"; do
        SPEC="$(case_spec "$C")"
        [[ -z "$SPEC" ]] && continue
        KIND=$(echo "$SPEC" | awk '{print $1}')
        FILE=$(echo "$SPEC" | awk '{print $2}')
        CASE_ID=$(echo "$SPEC" | awk '{print $3}')

        # Case 5 is special: run only on C/D, only 1 trial, after a stop+start.
        if [[ "$C" == "5" ]]; then
            if [[ "$NO_POST_RESTART" -eq 1 ]]; then continue; fi
            case "$COND" in C|D) ;; *) continue ;; esac

            # Preserve pre-restart live log (localclaude truncates on next start).
            if [[ -f "$LIVE_LOG" ]]; then
                cp "$LIVE_LOG" "$SERVER_LOG"
            fi
            PRE_RESTART_BYTES=$(log_size "$SERVER_LOG")
            stop_server
            if ! start_server_for "$COND"; then
                rec=$(python3 - <<PY
import json
print(json.dumps({
    "condition": "$COND",
    "case": "$CASE_ID",
    "trial": 1,
    "status": "server-start-failed",
    "error_class": "server-start-failed",
}))
PY
)
                write_record "$rec"
                continue
            fi
            POST_BOOT_OFFSET=$(( $(log_size "$LIVE_LOG") + PRE_RESTART_BYTES ))

            CURRENT_CASE="$CASE_ID"; CURRENT_TRIAL=1; TRIAL_IN_PROGRESS=1
            STARTED_AT="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))')"
            PRE=$(( $(log_size "$LIVE_LOG") + PRE_RESTART_BYTES ))
            CASE_OUT="$(run_case_cc "$CASES_DIR/$FILE" "$ACTIVE_MODEL" "$OUT_DIR/.case_out.json"; cat "$OUT_DIR/.case_out.json")"
            POST=$(( $(log_size "$LIVE_LOG") + PRE_RESTART_BYTES ))
            REC="$(compose_record "$COND" "$CASE_ID" 1 "$STARTED_AT" "$PRE" "$POST" "$POST_BOOT_OFFSET" "$CASE_OUT" "boot_offset_post_restart=$POST_BOOT_OFFSET")"
            write_record "$REC"
            TRIAL_IN_PROGRESS=0
            continue
        fi

        for ((T=1; T<=TRIALS; T++)); do
            CURRENT_CASE="$CASE_ID"; CURRENT_TRIAL="$T"; TRIAL_IN_PROGRESS=1
            STARTED_AT="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))')"
            PRE=$(log_size "$LIVE_LOG")
            if [[ "$KIND" == "curl" ]]; then
                run_case_curl "$ACTIVE_MODEL" "$OUT_DIR/.case_out.json"
            else
                run_case_cc "$CASES_DIR/$FILE" "$ACTIVE_MODEL" "$OUT_DIR/.case_out.json"
            fi
            CASE_OUT="$(cat "$OUT_DIR/.case_out.json")"
            POST=$(log_size "$LIVE_LOG")
            REC="$(compose_record "$COND" "$CASE_ID" "$T" "$STARTED_AT" "$PRE" "$POST" "$BOOT_OFFSET" "$CASE_OUT")"
            write_record "$REC"
            TRIAL_IN_PROGRESS=0
        done
    done

    stop_server
    if [[ -f "$LIVE_LOG" ]]; then
        cat "$LIVE_LOG" >> "$SERVER_LOG"
    fi
done

rm -f "$OUT_DIR/.case_out.json"

# ── Analysis ─────────────────────────────────────────────────────────
echo
echo "[analyze] $OUT_DIR"
python3 "$BENCH_DIR/analyze.py" --run-dir "$OUT_DIR"
echo "Run complete. summary.md at $OUT_DIR/summary.md"
