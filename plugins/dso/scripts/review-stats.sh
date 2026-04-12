#!/usr/bin/env bash
# review-stats.sh
# Thin bash wrapper for review-stats.py.
#
# Resolves .review-events/ from the tickets tracker directory and passes
# CLI arguments through to the Python module.
#
# Usage: review-stats.sh [--since=YYYY-MM-DD] [--all]
#
# Exit codes:
#   0 = success (including when no events are found)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Resolve .review-events/ directory ────────────────────────────────────────
# Allow tests to inject a custom tracker directory via TICKETS_TRACKER_DIR.
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
elif [ -n "${GIT_DIR:-}" ]; then
    REPO_ROOT="$(dirname "$GIT_DIR")"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
else
    REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

EVENTS_DIR="$TRACKER_DIR/.review-events"

# ── Graceful handling of missing/empty events directory ──────────────────────
if [ ! -d "$EVENTS_DIR" ]; then
    echo "No events found"
    exit 0
fi

# Check if directory has any .jsonl files
jsonl_count=$(find "$EVENTS_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l)
if [ "$jsonl_count" -eq 0 ]; then
    echo "No events found"
    exit 0
fi

# ── Parse CLI args and forward to Python ─────────────────────────────────────
py_args=("--events-dir=$EVENTS_DIR")

for arg in "$@"; do
    case "$arg" in
        --since=*)
            py_args+=("$arg")
            ;;
        --all)
            py_args+=("$arg")
            ;;
        -h|--help)
            py_args+=("$arg")
            ;;
        *)
            echo "Error: unknown argument '$arg'" >&2
            echo "Usage: review-stats.sh [--since=YYYY-MM-DD] [--all]" >&2
            exit 1
            ;;
    esac
done

# ── Invoke Python module with timeout guard ──────────────────────────────────
# Best-effort: catch Python failures to honor exit-0 contract
timeout 30 python3 "$SCRIPT_DIR/review-stats.py" "${py_args[@]}" || {
    echo "Warning: review-stats.py failed (exit $?)" >&2
    exit 0
}
