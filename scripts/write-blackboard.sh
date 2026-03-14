#!/usr/bin/env bash
# lockpick-workflow/scripts/write-blackboard.sh — Write .worktree-blackboard.json from batch JSON.
#
# Reads batch JSON (output of `sprint-next-batch.sh --json`) from stdin and
# writes `.worktree-blackboard.json` with atomic write semantics (write to
# `.worktree-blackboard.json.tmp`, then `mv`).
#
# Flags:
#   --clean   Remove .worktree-blackboard.json (idempotent)
#   --help    Print usage and exit 0
#
# Environment:
#   BLACKBOARD_DIR  Override directory for blackboard file (default: repo root)
#
# Schema (version 1):
# {
#   "version": 1,
#   "batch_id": "<timestamp-based>",
#   "created_at": "<ISO 8601>",
#   "agents": [
#     {
#       "task_id": "w22-xpcq",
#       "files_owned": ["scripts/write-blackboard.sh", "scripts/tests/test-write-blackboard.sh"],
#       "status": "dispatched"
#     }
#   ]
# }
#
# The script extracts `id` and `files` from each entry in the `batch` array of
# `sprint-next-batch.sh --json` output, mapping `files` to `files_owned` and
# setting `status: dispatched` for all agents.
#
# Exit codes:
#   0 — Success
#   1 — Missing/empty/invalid stdin
#   2 — Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Allow override for testing
BLACKBOARD_DIR="${BLACKBOARD_DIR:-$REPO_ROOT}"
BLACKBOARD_FILE="$BLACKBOARD_DIR/.worktree-blackboard.json"
BLACKBOARD_TMP="$BLACKBOARD_DIR/.worktree-blackboard.json.tmp"

usage() {
    cat <<EOF
Usage: write-blackboard.sh [--clean] [--help]

  Reads batch JSON from stdin (sprint-next-batch.sh --json output) and writes
  .worktree-blackboard.json with atomic write semantics.

  --clean   Remove .worktree-blackboard.json (idempotent)
  --help    Print this message and exit 0

  Environment:
    BLACKBOARD_DIR  Override directory for blackboard file (default: repo root)
EOF
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
mode="write"
for arg in "$@"; do
    case "$arg" in
        --clean)
            mode="clean"
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown flag: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# --clean mode
# ---------------------------------------------------------------------------
if [[ "$mode" == "clean" ]]; then
    rm -f "$BLACKBOARD_FILE" "$BLACKBOARD_TMP"
    exit 0
fi

# ---------------------------------------------------------------------------
# Write mode: read stdin
# ---------------------------------------------------------------------------
input=$(cat)

if [[ -z "$input" ]]; then
    echo "ERROR: No input on stdin. Pipe sprint-next-batch.sh --json output." >&2
    exit 1
fi

# Validate input is JSON with a batch array
if ! echo "$input" | jq -e '.batch' >/dev/null 2>&1; then
    echo "ERROR: Input is not valid JSON or missing 'batch' array." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the blackboard JSON
# ---------------------------------------------------------------------------
batch_id="batch-$(date +%s)-$$"
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use jq to transform the batch array into the blackboard schema
blackboard_json=$(echo "$input" | jq \
    --arg version "1" \
    --arg batch_id "$batch_id" \
    --arg created_at "$created_at" \
    '{
        version: ($version | tonumber),
        batch_id: $batch_id,
        created_at: $created_at,
        agents: [.batch[] | {
            task_id: .id,
            files_owned: .files,
            status: "dispatched"
        }]
    }')

# ---------------------------------------------------------------------------
# Atomic write: tmp + mv
# ---------------------------------------------------------------------------
echo "$blackboard_json" > "$BLACKBOARD_TMP"
mv "$BLACKBOARD_TMP" "$BLACKBOARD_FILE"

exit 0
