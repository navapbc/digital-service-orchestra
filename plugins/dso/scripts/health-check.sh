#!/usr/bin/env bash
set -uo pipefail
# scripts/health-check.sh
# Hook state health-check and auto-repair script.
#
# Scans all hook state files, reports their age/content/validity as JSON,
# and in --fix mode auto-repairs stale/orphaned state.
#
# Usage:
#   health-check.sh [--fix]
#
# Output:
#   JSON on stdout: {"files":[{path,age_seconds,content,status}],"summary":{total,ok,issues}}
#
# --fix mode repairs:
#   - Resets cascade counter to 0
#   - Removes orphaned test-status/*.status files (dead PIDs)
#
# State files scanned:
#   $ARTIFACTS_DIR/review-status
#   $ARTIFACTS_DIR/test-status/*.status
#   /tmp/claude-cascade-<worktree-hash>/counter
#
# Exit codes:
#   0  Always (non-blocking diagnostic)

# ── Resolve script dir and source deps ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
FIX_MODE=false
for arg in "$@"; do
    case "$arg" in
        --fix) FIX_MODE=true ;;
    esac
done

# ── Resolve key directories ───────────────────────────────────────────────────
ARTIFACTS_DIR=$(get_artifacts_dir)
REPO_ROOT=$(resolve_repo_root)

# ── Helper: get file modification time in epoch seconds ──────────────────────
_file_mtime() {
    local f="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f %m "$f" 2>/dev/null || echo 0
    else
        stat -c %Y "$f" 2>/dev/null || echo 0
    fi
}

# ── Helper: compute worktree hash (same algorithm as track-cascade-failures.sh)
_worktree_hash() {
    local root="$1"
    if command -v md5 &>/dev/null; then
        echo -n "$root" | md5
    elif command -v md5sum &>/dev/null; then
        echo -n "$root" | md5sum | cut -d' ' -f1
    else
        echo -n "$root" | cksum | cut -d' ' -f1
    fi
}

# ── Helper: JSON-escape a string ─────────────────────────────────────────────
_json_escape() {
    local s="$1"
    printf '%s' "$s" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" 2>/dev/null || printf '"%s"' "$s"
}

# ── Collect file entries ──────────────────────────────────────────────────────
NOW=$(date +%s)
FILES_JSON=""
TOTAL=0
OK=0
ISSUES=0

# Append a file entry to FILES_JSON.
# Args: path status age_seconds content
_append_entry() {
    local path="$1" status="$2" age="$3" content="$4"
    local escaped_path escaped_content
    escaped_path=$(_json_escape "$path")
    escaped_content=$(_json_escape "$content")

    local entry="{\"path\":${escaped_path},\"age_seconds\":${age},\"content\":${escaped_content},\"status\":\"${status}\"}"

    if [[ -z "$FILES_JSON" ]]; then
        FILES_JSON="$entry"
    else
        FILES_JSON="${FILES_JSON},${entry}"
    fi

    (( TOTAL++ )) || true
    if [[ "$status" == "ok" ]]; then
        (( OK++ )) || true
    else
        (( ISSUES++ )) || true
    fi
}

# ── Scan: review-status ───────────────────────────────────────────────────────
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
STALE_REVIEW_THRESHOLD=$(( 4 * 3600 ))  # 4 hours in seconds

if [[ -f "$REVIEW_STATUS_FILE" ]]; then
    mtime=$(_file_mtime "$REVIEW_STATUS_FILE")
    age=$(( NOW - mtime ))
    content=$(head -n 1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "")

    if (( age > STALE_REVIEW_THRESHOLD )); then
        _append_entry "$REVIEW_STATUS_FILE" "stale" "$age" "$content"
    else
        _append_entry "$REVIEW_STATUS_FILE" "ok" "$age" "$content"
    fi
fi

# ── Scan: test-status/*.status ────────────────────────────────────────────────
STATUS_DIR="$ARTIFACTS_DIR/test-status"
if [[ -d "$STATUS_DIR" ]]; then
    for status_file in "$STATUS_DIR"/*.status; do
        [[ -f "$status_file" ]] || continue

        mtime=$(_file_mtime "$status_file")
        age=$(( NOW - mtime ))
        content=$(head -n 5 "$status_file" 2>/dev/null || echo "")

        # Extract embedded PID (format: pid=<number>)
        embedded_pid=""
        if grep -q '^pid=' "$status_file" 2>/dev/null; then
            embedded_pid=$(grep '^pid=' "$status_file" | head -n 1 | cut -d= -f2)
        fi

        status="ok"
        if [[ -n "$embedded_pid" ]] && [[ "$embedded_pid" =~ ^[0-9]+$ ]]; then
            # Check if PID is alive
            if ! kill -0 "$embedded_pid" 2>/dev/null; then
                status="orphaned"
                if [[ "$FIX_MODE" == "true" ]]; then
                    rm -f "$status_file"
                fi
            fi
        fi

        _append_entry "$status_file" "$status" "$age" "$content"
    done
fi

# ── Scan: cascade counter ─────────────────────────────────────────────────────
if [[ -n "$REPO_ROOT" ]]; then
    WT_HASH=$(_worktree_hash "$REPO_ROOT")
    CASCADE_DIR="/tmp/claude-cascade-${WT_HASH}"
    COUNTER_FILE="$CASCADE_DIR/counter"

    if [[ -f "$COUNTER_FILE" ]]; then
        mtime=$(_file_mtime "$COUNTER_FILE")
        age=$(( NOW - mtime ))
        counter_val=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")

        if ! [[ "$counter_val" =~ ^[0-9]+$ ]]; then
            status="corrupted"
        elif (( counter_val > 0 )); then
            status="cascade"
        else
            status="ok"
        fi

        if [[ "$FIX_MODE" == "true" ]] && [[ "$status" != "ok" ]]; then
            echo "0" > "$COUNTER_FILE"
            # Also remove the error hash file so next run starts clean
            rm -f "$CASCADE_DIR/last-error-hash"
        fi

        _append_entry "$COUNTER_FILE" "$status" "$age" "$counter_val"
    fi
fi

# ── Emit JSON report ──────────────────────────────────────────────────────────
python3 -c "
import json, sys
files_raw = sys.argv[1]
total = int(sys.argv[2])
ok = int(sys.argv[3])
issues = int(sys.argv[4])

# Parse the pre-built JSON array fragment (may be empty)
if files_raw:
    files = json.loads('[' + files_raw + ']')
else:
    files = []

report = {
    'files': files,
    'summary': {
        'total': total,
        'ok': ok,
        'issues': issues
    }
}
print(json.dumps(report))
" "$FILES_JSON" "$TOTAL" "$OK" "$ISSUES"
