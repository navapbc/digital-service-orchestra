#!/usr/bin/env bash
# tests/scripts/test-retro-gather-suggestions.sh
# Tests for SUGGESTION_DATA section in retro-gather.sh.
#
# Covers:
#   1. SUGGESTION_DATA section present when .suggestions/ contains JSON records
#   2. SUGGESTION_DATA section omitted when .suggestions/ is empty (runtime check)
#   3. SUGGESTION_DATA section omitted when .suggestions/ does not exist (runtime check)
#   4. Clusters ranked by frequency (higher count first)
#   5. Cluster output includes file, pattern, count, and proposed_edit fields
#
# Strategy: each behavioral test runs retro-gather.sh with a background kill timer
# (10-15s) to prevent exceeding the ~73s Bash tool timeout ceiling. Tests 2 and 3
# use separate short-lived runs to check SUGGESTION_DATA absence.
#
# Usage: bash tests/scripts/test-retro-gather-suggestions.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
SCRIPT="$PLUGIN_ROOT/scripts/retro-gather.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-retro-gather-suggestions.sh ==="

# ── Build a test repo with suggestions ONCE ───────────────────────────────────
_REPO_WITH=$(mktemp -d)
_CLEANUP_DIRS+=("$_REPO_WITH")
clone_test_repo "$_REPO_WITH/repo"
mkdir -p "$_REPO_WITH/repo/.tickets-tracker/.suggestions"

# src/app.py + slow_query: 3 occurrences → frequency 3 (highest)
for i in 1 2 3; do
    cat > "$_REPO_WITH/repo/.tickets-tracker/.suggestions/a${i}.json" <<EOF
{
  "timestamp": "2026-04-09T10:0${i}:00Z",
  "session_id": "test-s1",
  "source": "stop-hook",
  "observation": "Slow query iteration $i",
  "recommendation": "add_index",
  "affected_file": "src/app.py",
  "skill_name": "slow_query"
}
EOF
done

# src/utils.py + missing_cache: 1 occurrence → frequency 1 (lower)
cat > "$_REPO_WITH/repo/.tickets-tracker/.suggestions/b1.json" <<EOF
{
  "timestamp": "2026-04-09T10:04:00Z",
  "session_id": "test-s2",
  "source": "stop-hook",
  "observation": "Missing cache hit",
  "recommendation": "add_cache",
  "affected_file": "src/utils.py",
  "skill_name": "missing_cache"
}
EOF

# ── Run retro-gather.sh ONCE, kill after timeout ──────────────────────────────
echo "Collecting output from repo with suggestions (this may take up to ${RETRO_GATHER_TEST_TIMEOUT:-15}s)..."
_timeout="${RETRO_GATHER_TEST_TIMEOUT:-15}"
_tmpout=$(mktemp)
trap 'rm -f "$_tmpout"' EXIT

PROJECT_ROOT="$_REPO_WITH/repo" \
    TRACKER_DIR="$_REPO_WITH/repo/.tickets-tracker" \
    CI_STATUS=pending \
    bash "$SCRIPT" --quick >"$_tmpout" 2>&1 &
_PID=$!
( sleep "$_timeout" && kill "$_PID" 2>/dev/null ) &
_TIMER=$!
wait "$_PID" 2>/dev/null || true
kill "$_TIMER" 2>/dev/null; wait "$_TIMER" 2>/dev/null || true
OUTPUT=$(cat "$_tmpout")
rm -f "$_tmpout"

# ── Test 1: SUGGESTION_DATA present when .suggestions/ has records ───────────
echo "Test 1: SUGGESTION_DATA section present when .suggestions/ has JSON records"
assert_contains "SUGGESTION_DATA section present" "SUGGESTION_DATA" "$OUTPUT"

# ── Test 2: SUGGESTION_DATA omitted when .suggestions/ exists but is empty ────
echo "Test 2: SUGGESTION_DATA section omitted when .suggestions/ has no JSON files"
_empty_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_empty_repo")
clone_test_repo "$_empty_repo/repo"
mkdir -p "$_empty_repo/repo/.tickets-tracker/.suggestions"  # empty directory

_empty_tmp=$(mktemp)
trap 'rm -f "$_empty_tmp"' EXIT
_empty_timeout=10
PROJECT_ROOT="$_empty_repo/repo" \
    TRACKER_DIR="$_empty_repo/repo/.tickets-tracker" \
    CI_STATUS=pending \
    bash "$SCRIPT" --quick >"$_empty_tmp" 2>&1 &
_empty_pid=$!
( sleep "$_empty_timeout" && kill "$_empty_pid" 2>/dev/null ) &
_empty_timer=$!
wait "$_empty_pid" 2>/dev/null || true
kill "$_empty_timer" 2>/dev/null; wait "$_empty_timer" 2>/dev/null || true
_empty_out=$(cat "$_empty_tmp")
rm -f "$_empty_tmp"
_has_section=0
[[ "$_empty_out" == *"SUGGESTION_DATA"* ]] && _has_section=1
assert_eq "SUGGESTION_DATA absent when .suggestions/ is empty" "0" "$_has_section"

# ── Test 3: SUGGESTION_DATA omitted when .suggestions/ does not exist ─────────
echo "Test 3: SUGGESTION_DATA section omitted when .suggestions/ does not exist"
_nodir_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_nodir_repo")
clone_test_repo "$_nodir_repo/repo"
# Intentionally do NOT create .suggestions/ directory

_nodir_tmp=$(mktemp)
trap 'rm -f "$_nodir_tmp"' EXIT
_nodir_timeout=10
PROJECT_ROOT="$_nodir_repo/repo" \
    TRACKER_DIR="$_nodir_repo/repo/.tickets-tracker" \
    CI_STATUS=pending \
    bash "$SCRIPT" --quick >"$_nodir_tmp" 2>&1 &
_nodir_pid=$!
( sleep "$_nodir_timeout" && kill "$_nodir_pid" 2>/dev/null ) &
_nodir_timer=$!
wait "$_nodir_pid" 2>/dev/null || true
kill "$_nodir_timer" 2>/dev/null; wait "$_nodir_timer" 2>/dev/null || true
_nodir_out=$(cat "$_nodir_tmp")
rm -f "$_nodir_tmp"
_nodir_has_section=0
[[ "$_nodir_out" == *"SUGGESTION_DATA"* ]] && _nodir_has_section=1
assert_eq "SUGGESTION_DATA absent when .suggestions/ does not exist" "0" "$_nodir_has_section"

# ── Test 4: Clusters ranked by frequency ────────────────────────────────────
echo "Test 4: SUGGESTION_DATA clusters ranked by frequency (highest count first)"

has_app="0"; has_utils="0"
[[ "$OUTPUT" == *"src/app.py"* ]] && has_app="1"
[[ "$OUTPUT" == *"src/utils.py"* ]] && has_utils="1"

assert_eq "higher-frequency file present in output" "1" "$has_app"
assert_eq "lower-frequency file present in output" "1" "$has_utils"

# Higher frequency (src/app.py, count=3) must appear before lower (src/utils.py, count=1)
_pos_app=$(echo "$OUTPUT" | grep -n "src/app.py" | head -1 | cut -d: -f1)
_pos_utils=$(echo "$OUTPUT" | grep -n "src/utils.py" | head -1 | cut -d: -f1)

if [ -n "$_pos_app" ] && [ -n "$_pos_utils" ]; then
    assert_eq "higher-freq cluster appears before lower-freq" "1" \
        "$([ "$_pos_app" -lt "$_pos_utils" ] && echo 1 || echo 0)"
else
    assert_eq "both clusters visible for frequency check" "both-present" \
        "app=${_pos_app:-missing} utils=${_pos_utils:-missing}"
fi

# ── Test 5: Cluster output includes required fields ───────────────────────────
echo "Test 5: SUGGESTION_DATA cluster output includes file, pattern, count, proposed_edit"

assert_contains "cluster contains affected_file (src/app.py)" "src/app.py" "$OUTPUT"
assert_contains "cluster contains skill_name (slow_query)" "slow_query" "$OUTPUT"
assert_contains "cluster contains proposed_edit (add_index)" "add_index" "$OUTPUT"
assert_contains "highest-ranked cluster shows count=3" "count=3" "$OUTPUT"

print_summary
