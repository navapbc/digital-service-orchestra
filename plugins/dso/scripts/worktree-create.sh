#!/bin/bash
set -euo pipefail
# worktree-create.sh — Create and initialize a git worktree ready for a Claude session
#
# Generic plugin version: no project-specific hardcoding. All project-specific
# behavior is driven by dso-config.conf (via read-config.sh).
#
# Usage:
#   worktree-create.sh [OPTIONS]
#
# Options:
#   --name=NAME           Worktree name (default: worktree-YYYYMMDD-HHMMSS)
#   --dir=DIR             Parent directory for worktrees
#                         (default: $LOCKPICK_WORKTREE_DIR or <repo-parent>/<repo-name>-worktrees)
#   --skip-pull           Skip git pull before creating worktree
#   --validation=STATE    Write initial validation state file.
#                         'skipped'  — write a skipped state (agent won't be blocked)
#                         'not_run'  — don't write a state file (default; agent will be warned)
#
# Output:
#   Prints the created worktree path to stdout on success.
#   All progress/warning messages go to stderr.
#
# Exit codes:
#   0 — Worktree created and ready
#   1 — Failed to create worktree or post-create hook failed

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

WORKTREE_NAME=""
WORKTREE_DIR_OVERRIDE=""
SKIP_PULL=0
VALIDATION_STATE="not_run"

# ── Progress helper ──────────────────────────────────────────────────────────
# Runs a command in the background, printing a dot every 2 s until it finishes.
# Output: "  label... done\n" or "  label... failed\n" — no extra newlines.
# Usage: _run_with_dots "Label" cmd [args...]
_run_with_dots() {
    local label="$1"; shift
    printf "  %s" "$label" >&2
    "$@" &>/dev/null &
    local pid=$! rc=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        printf "." >&2
    done
    wait "$pid" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf " done\n" >&2
    else
        printf " failed\n" >&2
    fi
    return "$rc"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --name=*)       WORKTREE_NAME="${arg#--name=}" ;;
        --dir=*)        WORKTREE_DIR_OVERRIDE="${arg#--dir=}" ;;
        --skip-pull)    SKIP_PULL=1 ;;
        --validation=*) VALIDATION_STATE="${arg#--validation=}" ;;
        --help)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ── Locate repo root ─────────────────────────────────────────────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not inside a git repository." >&2
    exit 1
fi

# Must be called from the main repo, not from an existing worktree
if [ -f "$REPO_ROOT/.git" ]; then
    echo "ERROR: Already inside a worktree. Run from the main repository." >&2
    exit 1
fi

# ── Resolve script and config paths ──────────────────────────────────────────
# Prefer read-config.sh relative to REPO_ROOT (works in both real repos and
# smoke-test temp repos where the script is copied into place).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config-paths.sh for CFG_PYTHON_VENV
_wt_config_paths="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/config-paths.sh"
[[ -f "$_wt_config_paths" ]] && source "$_wt_config_paths"

# Source deps.sh for retry_with_backoff
_wt_deps="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/deps.sh"
[[ -f "$_wt_deps" ]] && source "$_wt_deps"

if [ -x "${CLAUDE_PLUGIN_ROOT:-}/scripts/read-config.sh" ]; then
    READ_CONFIG="${CLAUDE_PLUGIN_ROOT:-}/scripts/read-config.sh"
else
    READ_CONFIG="$SCRIPT_DIR/read-config.sh"
fi

# ── Resolve name and directory ───────────────────────────────────────────────

if [ -z "$WORKTREE_NAME" ]; then
    WORKTREE_NAME="worktree-$(date +%Y%m%d-%H%M%S)"
fi

# Derive worktree directory from repo basename (no hardcoded project name)
REPO_BASENAME="$(basename "$REPO_ROOT")"
DEFAULT_WORKTREE_DIR="$(dirname "$REPO_ROOT")/${REPO_BASENAME}-worktrees"
WORKTREE_DIR="${WORKTREE_DIR_OVERRIDE:-${LOCKPICK_WORKTREE_DIR:-$DEFAULT_WORKTREE_DIR}}"
WORKTREE_PATH="$WORKTREE_DIR/$WORKTREE_NAME"

echo "Creating worktree: $WORKTREE_NAME (in $WORKTREE_DIR)" >&2
echo "" >&2

# ── Auto-cleanup or nudge if many worktrees exist ────────────────────────────

WORKTREE_COUNT=$(git worktree list 2>/dev/null | grep -c "worktree-" || true)
if [ "$WORKTREE_COUNT" -ge 10 ]; then
    echo "You have $WORKTREE_COUNT worktrees. Running automatic cleanup..." >&2
    echo "" >&2
    CLEANUP_SCRIPT="${CLAUDE_PLUGIN_ROOT:-}/scripts/worktree-cleanup.sh"
    if [ -x "$CLEANUP_SCRIPT" ]; then
        "$CLEANUP_SCRIPT" --all --force --include-branches >&2 || true
    else
        echo "Warning: worktree-cleanup.sh not found at $CLEANUP_SCRIPT" >&2
    fi
    echo "" >&2
elif [ "$WORKTREE_COUNT" -ge 4 ]; then
    echo "Note: You have $WORKTREE_COUNT worktrees. Run 'worktree-cleanup.sh' to remove merged ones." >&2
    echo "" >&2
fi

# ── Pull latest changes ──────────────────────────────────────────────────────

if [ "$SKIP_PULL" -eq 0 ]; then
    CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)
    if [ -z "$CURRENT_BRANCH" ]; then
        echo "  Skipping git pull (detached HEAD state)" >&2
    elif ! _run_with_dots "Pulling latest from origin" git -C "$REPO_ROOT" pull origin "$CURRENT_BRANCH"; then
        echo "  WARNING: git pull failed — continuing with current state" >&2
    fi
    echo "" >&2
fi

# ── Create worktree ──────────────────────────────────────────────────────────

mkdir -p "$WORKTREE_DIR"
CREATED=0

printf "  Creating worktree..." >&2
if type retry_with_backoff &>/dev/null; then
    if retry_with_backoff 3 2 git worktree add "$WORKTREE_PATH" -b "$WORKTREE_NAME" &>/dev/null; then
        CREATED=1
    fi
else
    if git worktree add "$WORKTREE_PATH" -b "$WORKTREE_NAME" &>/dev/null; then
        CREATED=1
    fi
fi

if [ "$CREATED" -eq 0 ] || [ ! -d "$WORKTREE_PATH" ]; then
    printf " failed\n" >&2
    echo "ERROR: Failed to create worktree at $WORKTREE_PATH" >&2
    echo "Create one manually: git worktree add $WORKTREE_PATH -b $WORKTREE_NAME" >&2
    exit 1
fi
printf " done\n" >&2

# ── Run post-create hook (config-driven) ─────────────────────────────────────

POST_CREATE_CMD=""
if [ -x "$READ_CONFIG" ]; then
    POST_CREATE_CMD=$("$READ_CONFIG" "worktree.post_create_cmd" 2>/dev/null || echo "")
fi

if [ -n "$POST_CREATE_CMD" ]; then
    echo "" >&2
    echo "  Running post-create hook: $POST_CREATE_CMD" >&2
    export WORKTREE_PATH
    HOOK_STDERR=""
    HOOK_RC=0
    HOOK_STDERR=$(cd "$WORKTREE_PATH" && eval "$POST_CREATE_CMD" 2>&1 >/dev/null) || HOOK_RC=$?

    if [ "$HOOK_RC" -ne 0 ]; then
        echo "  ERROR: Post-create hook failed (exit $HOOK_RC)" >&2
        if [ -n "$HOOK_STDERR" ]; then
            echo "  Hook stderr:" >&2
            printf '%s\n' "$HOOK_STDERR" | sed 's/^/    /' >&2
        fi
        echo "" >&2
        echo "  The worktree was created but the hook failed." >&2
        echo "  To remove it: git worktree remove $WORKTREE_PATH" >&2
        echo "  To retry the hook manually: WORKTREE_PATH=$WORKTREE_PATH $POST_CREATE_CMD" >&2
        exit 1
    fi
    echo "  Post-create hook completed successfully." >&2
else
    echo "" >&2
    echo "  No post-create hook configured — skipping environment setup." >&2
fi

# ── Set up validation artifacts directory ─────────────────────────────────────

# Read session.artifact_prefix from config, fall back to repo-name-derived default
ARTIFACT_PREFIX=""
if [ -x "$READ_CONFIG" ]; then
    ARTIFACT_PREFIX=$("$READ_CONFIG" "session.artifact_prefix" 2>/dev/null || echo "")
fi
if [ -z "$ARTIFACT_PREFIX" ]; then
    ARTIFACT_PREFIX="${REPO_BASENAME}-test-artifacts"
fi

VALIDATION_ARTIFACTS_DIR="/tmp/${ARTIFACT_PREFIX}-${WORKTREE_NAME}"
mkdir -p "$VALIDATION_ARTIFACTS_DIR"
VALIDATION_STATE_FILE="$VALIDATION_ARTIFACTS_DIR/status"

case "$VALIDATION_STATE" in
    skipped)
        echo "skipped" > "$VALIDATION_STATE_FILE"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VALIDATION_STATE_FILE"
        echo "reason=sub_agent" >> "$VALIDATION_STATE_FILE"
        ;;
    not_run)
        # Don't write a state file — validation gate will warn the agent
        ;;
    *)
        echo "WARNING: Unknown --validation value '$VALIDATION_STATE'. Defaulting to not_run." >&2
        ;;
esac

# ── Success: emit worktree path to stdout ─────────────────────────────────────

echo "$WORKTREE_PATH"
