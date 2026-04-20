#!/usr/bin/env bash
# test-ticket-perf.sh
# Verifies that ticket show and ticket list complete in <0.15s mean wall-clock
# using hyperfine. Skips gracefully if hyperfine is not installed.
#
# Story context: 78fc-3858 (bash-native ticket ops), 564c-e391 (perf gate),
# 9482-39dd (this test).
#
# Usage: bash tests/scripts/test-ticket-perf.sh
# Returns: exit 0 if both pass (or skip), exit 1 if either fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
BASELINE_FIXTURE="$REPO_ROOT/tests/fixtures/ticket-cli-baseline.json"

echo "=== test-ticket-perf.sh ==="
echo ""

# ── Step 1: Hyperfine availability check ─────────────────────────────────────
if ! command -v hyperfine >/dev/null 2>&1; then
    echo "SKIP: hyperfine not installed — skipping perf test"
    exit 0
fi

# ── Setup: temp repo with ticket system initialized ───────────────────────────
_CLEANUP_DIRS=()
# shellcheck disable=SC2329  # invoked via trap EXIT
_cleanup() {
    local d
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup EXIT

# Use git-fixtures for a fast ticket-ready repo
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

WORK_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$WORK_DIR")
clone_ticket_repo "$WORK_DIR/repo"
TEST_REPO="$WORK_DIR/repo"
TRACKER_DIR="$TEST_REPO/.tickets-tracker"

# ── Step 2: Create a test ticket ──────────────────────────────────────────────
TICKET_ID=$(
    cd "$TEST_REPO" && \
    _TICKET_TEST_NO_SYNC=1 \
    TICKETS_TRACKER_DIR="$TRACKER_DIR" \
    bash "$TICKET_SCRIPT" create task "perf-test-ticket" 2>/dev/null \
    | tr -d '[:space:]'
)

if [ -z "$TICKET_ID" ]; then
    echo "FAIL: setup — could not create test ticket"
    exit 1
fi
echo "Setup: created ticket $TICKET_ID in $TEST_REPO"
echo ""

# ── Helper: extract mean from hyperfine JSON ──────────────────────────────────
_extract_mean() {
    local json_file="$1"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
mean = data['results'][0]['mean']
print('{:.4f}'.format(mean))
" "$json_file"
}

# ── Helper: format mean for display ──────────────────────────────────────────
_format_mean() {
    local mean_s="$1"
    python3 -c "print('{:.4f}s'.format(float('$mean_s')))"
}

BENCH_SHOW_JSON="/tmp/bench-show-$$.json"
BENCH_LIST_JSON="/tmp/bench-list-$$.json"
_CLEANUP_FILES=("$BENCH_SHOW_JSON" "$BENCH_LIST_JSON")
# shellcheck disable=SC2329  # invoked via trap EXIT
_cleanup_files() {
    local f
    for f in "${_CLEANUP_FILES[@]:-}"; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
# Append file cleanup to EXIT trap (already set above via _cleanup)
trap '_cleanup; _cleanup_files' EXIT

THRESHOLD=0.15

# ── Step 3: Benchmark ticket show ─────────────────────────────────────────────
echo "--- Benchmarking: ticket show $TICKET_ID ---"
# Single-quote the variable expansions inside the hyperfine command string so
# that paths containing spaces survive bash --shell word-splitting.
if ! hyperfine \
    --warmup 3 \
    --runs 10 \
    --export-json "$BENCH_SHOW_JSON" \
    --shell bash \
    "_TICKET_TEST_NO_SYNC=1 TICKETS_TRACKER_DIR='$TRACKER_DIR' bash '$TICKET_SCRIPT' show '$TICKET_ID'" \
    2>&1; then
    echo "FAIL: hyperfine failed for ticket show"
    exit 1
fi
echo ""

# ── Step 4: Benchmark ticket list ─────────────────────────────────────────────
echo "--- Benchmarking: ticket list ---"
if ! hyperfine \
    --warmup 3 \
    --runs 10 \
    --export-json "$BENCH_LIST_JSON" \
    --shell bash \
    "_TICKET_TEST_NO_SYNC=1 TICKETS_TRACKER_DIR='$TRACKER_DIR' bash '$TICKET_SCRIPT' list" \
    2>&1; then
    echo "FAIL: hyperfine failed for ticket list"
    exit 1
fi
echo ""

# ── Step 5: Parse results and assert ─────────────────────────────────────────
SHOW_MEAN=$(_extract_mean "$BENCH_SHOW_JSON")
LIST_MEAN=$(_extract_mean "$BENCH_LIST_JSON")

SHOW_PASS=false
LIST_PASS=false

# Compare using python3 for reliable float comparison
if python3 -c "import sys; sys.exit(0 if float('$SHOW_MEAN') < $THRESHOLD else 1)"; then
    SHOW_PASS=true
    echo "PASS: ticket show mean=$(_format_mean "$SHOW_MEAN") (<${THRESHOLD}s)"
else
    echo "FAIL: ticket show mean=$(_format_mean "$SHOW_MEAN") (>=${THRESHOLD}s)"
fi

if python3 -c "import sys; sys.exit(0 if float('$LIST_MEAN') < $THRESHOLD else 1)"; then
    LIST_PASS=true
    echo "PASS: ticket list mean=$(_format_mean "$LIST_MEAN") (<${THRESHOLD}s)"
else
    echo "FAIL: ticket list mean=$(_format_mean "$LIST_MEAN") (>=${THRESHOLD}s)"
fi

# ── Step 6: Optional baseline comparison ────────────────────────────────────
if [ -f "$BASELINE_FIXTURE" ]; then
    echo ""
    echo "--- Baseline comparison (informational) ---"
    python3 - "$BASELINE_FIXTURE" "$SHOW_MEAN" "$LIST_MEAN" <<'PYEOF'
import json, sys

fixture_path, show_mean, list_mean = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
with open(fixture_path) as f:
    baseline = json.load(f)

def compare_op(op_name, current_mean):
    ops = baseline.get("ops", {})
    if op_name not in ops:
        print(f"  {op_name}: no baseline entry — skipping comparison")
        return
    baseline_mean = ops[op_name].get("mean_s")
    if baseline_mean is None:
        print(f"  {op_name}: no mean_s in baseline — skipping comparison")
        return
    delta = current_mean - baseline_mean
    sign = "+" if delta >= 0 else ""
    print(f"  {op_name}: current={current_mean:.4f}s  baseline={baseline_mean:.4f}s  delta={sign}{delta:.4f}s")

compare_op("show", show_mean)
compare_op("list", list_mean)
PYEOF
fi

# ── Exit ──────────────────────────────────────────────────────────────────────
echo ""
if $SHOW_PASS && $LIST_PASS; then
    echo "Results: both ticket show and ticket list within ${THRESHOLD}s threshold"
    exit 0
else
    echo "Results: one or more operations exceeded ${THRESHOLD}s threshold"
    exit 1
fi
