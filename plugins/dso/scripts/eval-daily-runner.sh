#!/usr/bin/env bash
# plugins/dso/scripts/eval-daily-runner.sh
# Daily eval runner: invokes run-skill-evals.sh --all and creates/updates
# a P0 bug ticket on failure.
#
# Usage: eval-daily-runner.sh [--help]
#
# Exit codes:
#   0  — all evals passed
#   1+ — evals failed (exit code propagated from run-skill-evals.sh)
#
# Environment variables (used for testing — override CLI paths):
#   MOCK_BIN_DIR — when set, the mock dso stub uses it to record calls

set -uo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" ]]; then
    cat <<EOF
Usage: eval-daily-runner.sh [--help]

Runs the full eval suite via run-skill-evals.sh --all.

On success (exit 0): logs success and exits 0.

On failure (exit non-zero):
  1. Parses failure count from eval output
  2. Generates ticket title: "EVAL REGRESSION: YYYY-MM-DD — N skills failing"
  3. Checks for existing open P0 bug with "EVAL REGRESSION:" title prefix
  4. If existing P0 found: appends comment with new failure details
  5. If no existing P0: creates new P0 bug ticket
  6. Exits non-zero (propagating the eval failure)

Ticket CLI: .claude/scripts/dso ticket <subcommand>
EOF
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { printf '[eval-daily-runner] %s\n' "$*"; }

# Find the dso CLI — prefer the one on PATH (supports test mocking)
_dso_cmd() {
    if command -v dso &>/dev/null; then
        dso "$@"
    else
        # Fall back to repo-relative path
        local repo_root
        repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        "$repo_root/.claude/scripts/dso" "$@"
    fi
}

# ── Run evals ─────────────────────────────────────────────────────────────────
TODAY="$(date +%Y-%m-%d)"
eval_output=""
eval_exit=0

# Resolve run-skill-evals.sh path — supports test mocking via PATH override
_EVALS_SCRIPT="$(command -v run-skill-evals.sh 2>/dev/null || echo "")"
if [[ -z "$_EVALS_SCRIPT" ]]; then
    # Fall back to repo-relative path
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _EVALS_SCRIPT="$_SCRIPT_DIR/run-skill-evals.sh"
fi
eval_output="$(bash "$_EVALS_SCRIPT" --all 2>&1)" || eval_exit=$?

if [[ "$eval_exit" -eq 0 ]]; then
    log "All evals passed on $TODAY."
    exit 0
fi

# ── Parse failure count ────────────────────────────────────────────────────────
# promptfoo outputs "N failed (M%)" in its results summary. Count the number of
# "Running eval:" lines that were followed by failures to get the skill count.
# Fallback: count "✗ N failed" lines from promptfoo output.
fail_count="$(printf '%s\n' "$eval_output" | grep -Eo '✗ [0-9]+ failed' | wc -l | tr -d ' ')"
if [[ "$fail_count" -eq 0 ]] 2>/dev/null; then
    # Alternative: count eval configs that had any failures
    fail_count="$(printf '%s\n' "$eval_output" | grep -c 'failed' | tr -d ' ')"
fi
if [[ "$fail_count" -eq 0 ]] 2>/dev/null || [[ -z "$fail_count" ]]; then
    fail_count="unknown"
fi

TITLE="EVAL REGRESSION: ${TODAY} — ${fail_count} skills failing"
DESCRIPTION="Daily eval run on ${TODAY}: ${fail_count} skill(s) failing.

Eval output:
${eval_output}"

# ── Dedup: check for existing open P0 EVAL REGRESSION ticket ──────────────────
existing_id=""
ticket_list_output=""
ticket_list_output="$(_dso_cmd ticket list 2>/dev/null || true)"

# Parse JSON array looking for: type=bug, priority=0, status=open, title prefix "EVAL REGRESSION:"
# The list returns a JSON array; use python3 for robust parsing
existing_id="$(python3 - <<'PYEOF'
import sys, json, os

raw = os.environ.get("DSO_MOCK_TICKET_LIST", "")
if not raw:
    # Read from stdin (passed via process substitution below)
    raw = sys.stdin.read().strip()

if not raw:
    sys.exit(0)

try:
    tickets = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

if not isinstance(tickets, list):
    sys.exit(0)

for t in tickets:
    title = t.get("title", "")
    status = t.get("status", "")
    priority = t.get("priority", -1)
    ticket_id = t.get("ticket_id", "")
    if (title.startswith("EVAL REGRESSION:") and
            status == "open" and
            priority == 0 and
            ticket_id):
        print(ticket_id)
        sys.exit(0)
PYEOF
<<< "$ticket_list_output"
)"

# ── Create or comment ──────────────────────────────────────────────────────────
if [[ -n "$existing_id" ]]; then
    log "Existing P0 EVAL REGRESSION ticket found: $existing_id — appending comment."
    _dso_cmd ticket comment "$existing_id" \
        "Daily eval run ${TODAY}: ${fail_count} skill(s) failing. Details: ${eval_output}"
else
    log "No existing P0 EVAL REGRESSION ticket — creating new P0 bug."
    _dso_cmd ticket create bug "$TITLE" -p 0 -d "$DESCRIPTION"
fi

# ── Propagate failure ──────────────────────────────────────────────────────────
exit "$eval_exit"
