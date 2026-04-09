#!/usr/bin/env bash
# plugins/dso/scripts/suggestion-record.sh
# Record an immutable suggestion JSON file to .tickets-tracker/.suggestions/
# on the tickets orphan branch using Python fcntl.flock (following ticket-flock-contract.md).
#
# Usage:
#   suggestion-record.sh --observation <text> --source <source> \
#       [--recommendation <text>] [--session-id <id>] \
#       [--skill-name <name>] [--affected-file <path>] \
#       [--metrics <json-object>]
#
# Required:
#   --source <source>      Who or what generated this suggestion (e.g., "stop-hook", "agent", "manual")
#
# Optional:
#   --observation <text>   Objective observation (what happened, what was measured)
#   --recommendation <text> Subjective recommendation (what to change, how to improve)
#   --session-id <id>      Session identifier (defaults to CLAUDE_SESSION_ID env var or random UUID)
#   --skill-name <name>    The skill that was running when the suggestion was captured
#   --affected-file <path> File most relevant to this suggestion
#   --metrics <json>       JSON object with numeric metrics (e.g. {"wall_clock_s": 45, "tokens": 3000})
#
# Exit codes:
#   0  — success: file written and committed
#   1  — error: missing arguments, tracker not initialized, or lock exhaustion
#
# Environment:
#   SUGGESTION_LOCK_TIMEOUT  — override flock timeout per attempt (default: 30s)
#   CLAUDE_SESSION_ID        — session identifier (used if --session-id not given)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the shared flock library
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
source_arg=""
observation_arg=""
recommendation_arg=""
session_id_arg=""
skill_name_arg=""
affected_file_arg=""
metrics_arg=""

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            source_arg="$2"; shift 2 ;;
        --source=*)
            source_arg="${1#--source=}"; shift ;;
        --observation)
            observation_arg="$2"; shift 2 ;;
        --observation=*)
            observation_arg="${1#--observation=}"; shift ;;
        --recommendation)
            recommendation_arg="$2"; shift 2 ;;
        --recommendation=*)
            recommendation_arg="${1#--recommendation=}"; shift ;;
        --session-id)
            session_id_arg="$2"; shift 2 ;;
        --session-id=*)
            session_id_arg="${1#--session-id=}"; shift ;;
        --skill-name)
            skill_name_arg="$2"; shift 2 ;;
        --skill-name=*)
            skill_name_arg="${1#--skill-name=}"; shift ;;
        --affected-file)
            affected_file_arg="$2"; shift 2 ;;
        --affected-file=*)
            affected_file_arg="${1#--affected-file=}"; shift ;;
        --metrics)
            metrics_arg="$2"; shift 2 ;;
        --metrics=*)
            metrics_arg="${1#--metrics=}"; shift ;;
        --help|-h)
            echo "Usage: suggestion-record.sh --source <source> [--observation <text>]" >&2
            echo "       [--recommendation <text>] [--session-id <id>] [--skill-name <name>]" >&2
            echo "       [--affected-file <path>] [--metrics <json>]" >&2
            exit 0
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            echo "Error: unexpected argument '$1'" >&2
            exit 1
            ;;
    esac
done

# ── Validate required arguments ──────────────────────────────────────────────
if [ -z "$source_arg" ]; then
    echo "Error: --source is required" >&2
    exit 1
fi

# ── Resolve repo root and tracker dir ────────────────────────────────────────
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "Error: cannot determine repository root" >&2
    exit 1
fi

TRACKER_DIR_RAW="$REPO_ROOT/.tickets-tracker"

# Graceful degradation: warn and exit non-zero if tracker not initialized
if [ ! -d "$TRACKER_DIR_RAW" ] || [ ! -f "$TRACKER_DIR_RAW/.git" ]; then
    echo "Error: ticket system not initialized (.tickets-tracker/ not found). Suggestion not recorded." >&2
    exit 1
fi

# Resolve canonical path (avoids symlink discrepancies per flock contract)
TRACKER_DIR=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$TRACKER_DIR_RAW")

SUGGESTIONS_DIR="$TRACKER_DIR/.suggestions"

# ── Ensure gc.auto=0 (idempotent guard, per flock contract) ──────────────────
git -C "$TRACKER_DIR" config gc.auto 0

# ── Resolve session_id ───────────────────────────────────────────────────────
if [ -n "$session_id_arg" ]; then
    SESSION_ID="$session_id_arg"
elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    SESSION_ID="$CLAUDE_SESSION_ID"
else
    # Generate a random session-id with sufficient entropy
    SESSION_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
fi

# ── Generate timestamp and UUID ───────────────────────────────────────────────
TIMESTAMP_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
FILE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

# ── Ensure .suggestions/ directory exists ────────────────────────────────────
mkdir -p "$SUGGESTIONS_DIR"

# ── Determine final filename and path ────────────────────────────────────────
# Naming: <timestamp_ms>-<session-id-prefix>-<uuid>.json
# Use first 8 chars of session_id, excluding hyphens to keep delimiter unambiguous
SESSION_PREFIX=$(echo "$SESSION_ID" | cut -c1-8 | tr -dc 'a-zA-Z0-9' | head -c8)
SESSION_PREFIX=${SESSION_PREFIX:-unknown}
FINAL_FILENAME="${TIMESTAMP_MS}-${SESSION_PREFIX}-${FILE_UUID}.json"
FINAL_PATH="$SUGGESTIONS_DIR/$FINAL_FILENAME"

# ── Stage temp in tracker_dir (same filesystem → atomic rename) ──────────────
STAGING_TEMP=$(mktemp "$TRACKER_DIR/.tmp-suggestion-stage-XXXXXX")
# Trap covers STAGING_TEMP immediately after creation to prevent leaks on SIGTERM/SIGINT.
trap 'rm -f "${STAGING_TEMP:-}"' EXIT

# Build JSON payload and write directly to staging temp (single python3 call).
# REVIEW-DEFENSE: Tests for --source required validation, --metrics JSON handling,
# and schema_version presence are in tests/scripts/test-suggestion-record.sh
# (test_source_required, test_metrics_valid, test_schema_version_present).
python3 -c "
import json, sys

timestamp_ms   = int(sys.argv[1])
session_id     = sys.argv[2]
source_val     = sys.argv[3]
observation    = sys.argv[4]
recommendation = sys.argv[5]
skill_name     = sys.argv[6]
affected_file  = sys.argv[7]
metrics_json   = sys.argv[8]
staging_path   = sys.argv[9]

data = {
    'schema_version': 1,
    'timestamp': timestamp_ms,
    'session_id': session_id,
    'source': source_val,
}

if observation:
    data['observation'] = observation
if recommendation:
    data['recommendation'] = recommendation
if skill_name:
    data['skill_name'] = skill_name
if affected_file:
    data['affected_file'] = affected_file
if metrics_json:
    try:
        data['metrics'] = json.loads(metrics_json)
    except json.JSONDecodeError as e:
        print(f'Error: invalid JSON for --metrics: {e}', file=sys.stderr)
        sys.exit(1)

with open(staging_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False)
" "$TIMESTAMP_MS" "$SESSION_ID" "$source_arg" "$observation_arg" "$recommendation_arg" \
  "$skill_name_arg" "$affected_file_arg" "$metrics_arg" "$STAGING_TEMP" || {
    echo "Error: failed to write suggestion payload" >&2
    exit 1
}

# ── Acquire flock, atomic rename, and commit ─────────────────────────────────
COMMIT_MSG="suggestion: RECORD"

# Honour SUGGESTION_LOCK_TIMEOUT to allow tests to use a short timeout
export FLOCK_STAGE_COMMIT_TIMEOUT="${SUGGESTION_LOCK_TIMEOUT:-30}"

_flock_stage_commit "$TRACKER_DIR" "$STAGING_TEMP" "$FINAL_PATH" "$COMMIT_MSG" || exit $?

# Clear the staging temp trap — file has been renamed (no longer exists)
trap - EXIT

# ── Best-effort push ─────────────────────────────────────────────────────────
_push_tickets_branch "$TRACKER_DIR"

echo "Suggestion recorded: $FINAL_FILENAME"
exit 0
