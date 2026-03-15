#!/usr/bin/env bash
set -euo pipefail
# lockpick-workflow/scripts/bench-hook-timing.sh
# Benchmark hook timing by enabling per-call timing, running sample hooks,
# and reporting the results.
#
# Usage:
#   bash lockpick-workflow/scripts/bench-hook-timing.sh
#
# What it does:
#   1. Enables hook timing (touch ~/.claude/hook-timing-enabled)
#   2. Runs sample hook invocations (pre-bash, post-bash dispatchers)
#   3. Reports timing data from /tmp/hook-timing.log
#   4. Cleans up (removes timing flag and log)
#
# NOTE: Tool logging is not logged for tools without dedicated dispatchers
# (Read, Glob, Grep, Skill, ToolSearch). This is an accepted tradeoff for
# reducing process count per tool call. Only Bash, Edit, and Write have
# dedicated dispatchers with tool logging.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
TIMING_FLAG="$HOME/.claude/hook-timing-enabled"
TIMING_LOG="/tmp/hook-timing.log"

# ── Setup ──────────────────────────────────────────────────
echo "=== Hook Timing Benchmark ==="
echo ""

# Create timing flag
mkdir -p "$HOME/.claude"
touch "$TIMING_FLAG"
rm -f "$TIMING_LOG"

echo "Timing enabled: $TIMING_FLAG"
echo ""

# ── Sample hook invocations ────────────────────────────────
SAMPLE_INPUT='{"tool":{"name":"Bash","input":{"command":"echo hello"}}}'

echo "--- Running pre-bash dispatcher ---"
echo "$SAMPLE_INPUT" | bash "$PLUGIN_ROOT/hooks/dispatchers/pre-bash.sh" 2>/dev/null || true
echo ""

echo "--- Running post-bash dispatcher ---"
echo "$SAMPLE_INPUT" | bash "$PLUGIN_ROOT/hooks/dispatchers/post-bash.sh" 2>/dev/null || true
echo ""

echo "--- Running pre-edit dispatcher ---"
EDIT_INPUT='{"tool":{"name":"Edit","input":{"file_path":"test.py","old_string":"a","new_string":"b"}}}'
echo "$EDIT_INPUT" | bash "$PLUGIN_ROOT/hooks/dispatchers/pre-edit.sh" 2>/dev/null || true
echo ""

echo "--- Running post-edit dispatcher ---"
echo "$EDIT_INPUT" | bash "$PLUGIN_ROOT/hooks/dispatchers/post-edit.sh" 2>/dev/null || true
echo ""

# ── Report ─────────────────────────────────────────────────
echo "=== Timing Results ==="
if [[ -f "$TIMING_LOG" ]]; then
    cat "$TIMING_LOG"
    echo ""

    # Summary: total time and call count
    total_calls=$(wc -l < "$TIMING_LOG" | tr -d ' ')
    total_ms=0
    while IFS=$'\t' read -r _time _hook ms _exit; do
        val="${ms%ms}"
        total_ms=$(( total_ms + val ))
    done < "$TIMING_LOG"

    echo "--- Summary ---"
    echo "Total hook calls: $total_calls"
    echo "Total time: ${total_ms}ms"
    if [[ "$total_calls" -gt 0 ]]; then
        avg=$(( total_ms / total_calls ))
        echo "Average per call: ${avg}ms"
    fi
else
    echo "(no timing data recorded)"
fi

# ── Cleanup ────────────────────────────────────────────────
echo ""
echo "Cleaning up..."
rm -f "$TIMING_FLAG"
rm -f "$TIMING_LOG"
echo "Done."
