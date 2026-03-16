#!/usr/bin/env bash
# tests/scripts/test-health-check.sh
# Tests for scripts/health-check.sh
#
# Usage: bash tests/scripts/test-health-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HEALTH_CHECK="$PLUGIN_ROOT/scripts/health-check.sh"

echo "=== test-health-check.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Override artifacts dir and repo root for all tests
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TMPDIR_TEST/artifacts"
export REPO_ROOT="$TMPDIR_TEST/repo"
mkdir -p "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
mkdir -p "$REPO_ROOT"

# ── Test: script exists and is executable ────────────────────────────────────
echo ""
echo "--- existence and permissions ---"
_snapshot_fail

if [[ -f "$HEALTH_CHECK" ]]; then
    (( ++PASS ))
    echo "script exists ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: $HEALTH_CHECK does not exist" >&2
fi

if [[ -x "$HEALTH_CHECK" ]]; then
    (( ++PASS ))
    echo "script is executable ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: $HEALTH_CHECK is not executable" >&2
fi

assert_pass_if_clean "script exists and is executable"

# ── Test: JSON output format ──────────────────────────────────────────────────
echo ""
echo "--- JSON output format ---"
_snapshot_fail

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TMPDIR_TEST/artifacts" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)
exit_code=$?

assert_eq "exits zero with no state files" "0" "$exit_code"
assert_contains "output contains 'files'" "\"files\"" "$OUTPUT"
assert_contains "output contains 'summary'" "\"summary\"" "$OUTPUT"
assert_contains "output contains 'total'" "\"total\"" "$OUTPUT"
assert_contains "output contains 'ok'" "\"ok\"" "$OUTPUT"
assert_contains "output contains 'issues'" "\"issues\"" "$OUTPUT"

# Verify it is valid JSON
if python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$OUTPUT" 2>/dev/null; then
    (( ++PASS ))
    echo "output is valid JSON ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: output is not valid JSON: $OUTPUT" >&2
fi

assert_pass_if_clean "JSON output format"

# ── Test: detects stale review-status (>4h old) ───────────────────────────────
echo ""
echo "--- stale review-status detection ---"
_snapshot_fail

# Create a review-status file with old mtime
REVIEW_STATUS_FILE="$TMPDIR_TEST/artifacts/review-status"
echo "passed" > "$REVIEW_STATUS_FILE"
# Make it 5 hours old (18000 seconds)
touch -d "5 hours ago" "$REVIEW_STATUS_FILE" 2>/dev/null || \
    touch -t "$(date -d '5 hours ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-5H +%Y%m%d%H%M.%S)" "$REVIEW_STATUS_FILE" 2>/dev/null || true

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TMPDIR_TEST/artifacts" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)

assert_contains "stale review-status flagged" "stale" "$OUTPUT"

assert_pass_if_clean "stale review-status detection"

# ── Test: fresh review-status is ok ─────────────────────────────────────────
echo ""
echo "--- fresh review-status is ok ---"
_snapshot_fail

# Create a fresh review-status file
FRESH_STATUS="$TMPDIR_TEST/artifacts2"
mkdir -p "$FRESH_STATUS"
echo "passed" > "$FRESH_STATUS/review-status"

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$FRESH_STATUS" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)

# Should contain the file but with status "ok"
assert_contains "fresh review-status is ok" "\"ok\"" "$OUTPUT"

assert_pass_if_clean "fresh review-status is ok"

# ── Test: detects test-status files from dead PIDs ───────────────────────────
echo ""
echo "--- test-status orphaned PID detection ---"
_snapshot_fail

ARTIFACTS3="$TMPDIR_TEST/artifacts3"
mkdir -p "$ARTIFACTS3/test-status"

# Write a test-status file with a dead PID (PID 1 is init, never dead, use very large number)
DEAD_PID=99999999
STATUS_FILE="$ARTIFACTS3/test-status/pytest-${DEAD_PID}.status"
printf 'FAILED\npid=%s\n' "$DEAD_PID" > "$STATUS_FILE"

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS3" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)

# The file should be detected (present in files array) and flagged as orphaned
assert_contains "test-status with dead PID flagged" "orphaned" "$OUTPUT"

assert_pass_if_clean "test-status orphaned PID detection"

# ── Test: test-status files without PID are not flagged orphaned ─────────────
echo ""
echo "--- test-status without PID ---"
_snapshot_fail

ARTIFACTS4="$TMPDIR_TEST/artifacts4"
mkdir -p "$ARTIFACTS4/test-status"

# Write a test-status file without an embedded PID (just a plain status)
echo "PASSED" > "$ARTIFACTS4/test-status/make-test.status"

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS4" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)

# Should appear in output but not flagged as orphaned
assert_contains "test-status file appears in output" "test-status" "$OUTPUT"

# Should not contain "orphaned" for this file if there is no PID
if echo "$OUTPUT" | python3 -c "
import json,sys
data=json.loads(sys.stdin.read())
orphaned=[f for f in data.get('files',[]) if 'test-status' in f.get('path','') and f.get('status')=='orphaned']
sys.exit(0 if not orphaned else 1)
" 2>/dev/null; then
    (( ++PASS ))
    echo "non-PID test-status not flagged orphaned ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: non-PID test-status file incorrectly flagged as orphaned" >&2
fi

assert_pass_if_clean "test-status without PID"

# ── Test: detects cascade counter > 0 ────────────────────────────────────────
echo ""
echo "--- cascade counter detection ---"
_snapshot_fail

# Compute worktree hash as the script does (using the REPO_ROOT override)
WT_HASH=""
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$TMPDIR_TEST/repo" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$TMPDIR_TEST/repo" | md5sum | cut -d' ' -f1)
else
    WT_HASH=$(echo -n "$TMPDIR_TEST/repo" | cksum | cut -d' ' -f1)
fi

CASCADE_DIR="/tmp/claude-cascade-${WT_HASH}"
mkdir -p "$CASCADE_DIR"
echo "3" > "$CASCADE_DIR/counter"

ARTIFACTS5="$TMPDIR_TEST/artifacts5"
mkdir -p "$ARTIFACTS5"

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS5" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" 2>/dev/null)

assert_contains "cascade counter detected" "cascade" "$OUTPUT"

# Cleanup cascade dir
rm -rf "$CASCADE_DIR"

assert_pass_if_clean "cascade counter detection"

# ── Test: --fix resets cascade counter ────────────────────────────────────────
echo ""
echo "--- --fix resets cascade counter ---"
_snapshot_fail

WT_HASH_FIX=""
if command -v md5 &>/dev/null; then
    WT_HASH_FIX=$(echo -n "$TMPDIR_TEST/repo" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH_FIX=$(echo -n "$TMPDIR_TEST/repo" | md5sum | cut -d' ' -f1)
else
    WT_HASH_FIX=$(echo -n "$TMPDIR_TEST/repo" | cksum | cut -d' ' -f1)
fi

CASCADE_DIR_FIX="/tmp/claude-cascade-${WT_HASH_FIX}"
mkdir -p "$CASCADE_DIR_FIX"
echo "4" > "$CASCADE_DIR_FIX/counter"
echo "somehash" > "$CASCADE_DIR_FIX/last-error-hash"

ARTIFACTS6="$TMPDIR_TEST/artifacts6"
mkdir -p "$ARTIFACTS6"

WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS6" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" --fix >/dev/null 2>&1

COUNTER_AFTER=$(cat "$CASCADE_DIR_FIX/counter" 2>/dev/null || echo "missing")
assert_eq "--fix resets cascade counter to 0" "0" "$COUNTER_AFTER"

# Cleanup cascade dir
rm -rf "$CASCADE_DIR_FIX"

assert_pass_if_clean "--fix resets cascade counter"

# ── Test: --fix removes stale test-status files from dead PIDs ──────────────
echo ""
echo "--- --fix removes orphaned test-status files ---"
_snapshot_fail

ARTIFACTS7="$TMPDIR_TEST/artifacts7"
mkdir -p "$ARTIFACTS7/test-status"

DEAD_PID2=99999998
ORPHAN_FILE="$ARTIFACTS7/test-status/pytest-${DEAD_PID2}.status"
printf 'FAILED\npid=%s\n' "$DEAD_PID2" > "$ORPHAN_FILE"

WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS7" REPO_ROOT="$TMPDIR_TEST/repo" \
    bash "$HEALTH_CHECK" --fix >/dev/null 2>&1

if [[ ! -f "$ORPHAN_FILE" ]]; then
    (( ++PASS ))
    echo "--fix removed orphaned test-status file ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: --fix did not remove orphaned test-status file $ORPHAN_FILE" >&2
fi

assert_pass_if_clean "--fix removes orphaned test-status files"

# ── Test: --fix clears orphaned checkpoint markers ────────────────────────────
echo ""
echo "--- --fix clears checkpoint markers ---"
_snapshot_fail

# Create fake checkpoint markers in a test repo root dir
FAKE_REPO="$TMPDIR_TEST/repo-chk"
mkdir -p "$FAKE_REPO"
# Initialize a bare git repo so we can check commit presence
touch "$FAKE_REPO/.checkpoint-pending-rollback"
touch "$FAKE_REPO/.checkpoint-needs-review"

ARTIFACTS8="$TMPDIR_TEST/artifacts8"
mkdir -p "$ARTIFACTS8"

WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS8" REPO_ROOT="$FAKE_REPO" \
    bash "$HEALTH_CHECK" --fix >/dev/null 2>&1

if [[ ! -f "$FAKE_REPO/.checkpoint-pending-rollback" ]]; then
    (( ++PASS ))
    echo "--fix removed .checkpoint-pending-rollback ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: --fix did not remove .checkpoint-pending-rollback" >&2
fi

if [[ ! -f "$FAKE_REPO/.checkpoint-needs-review" ]]; then
    (( ++PASS ))
    echo "--fix removed .checkpoint-needs-review ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: --fix did not remove .checkpoint-needs-review" >&2
fi

assert_pass_if_clean "--fix clears checkpoint markers"

# ── Test: --fix does not modify code files ────────────────────────────────────
echo ""
echo "--- --fix only modifies hook-managed files ---"
_snapshot_fail

ARTIFACTS9="$TMPDIR_TEST/artifacts9"
mkdir -p "$ARTIFACTS9"
FAKE_REPO2="$TMPDIR_TEST/repo-code"
mkdir -p "$FAKE_REPO2"

# Create a code file in the fake repo
CODE_FILE="$FAKE_REPO2/mycode.py"
echo "print('hello')" > "$CODE_FILE"
ORIGINAL_CONTENT=$(cat "$CODE_FILE")

WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS9" REPO_ROOT="$FAKE_REPO2" \
    bash "$HEALTH_CHECK" --fix >/dev/null 2>&1

CONTENT_AFTER=$(cat "$CODE_FILE" 2>/dev/null || echo "MISSING")
assert_eq "--fix does not modify code files" "$ORIGINAL_CONTENT" "$CONTENT_AFTER"

assert_pass_if_clean "--fix only modifies hook-managed files"

# ── Test: checkpoint markers detected in report ───────────────────────────────
echo ""
echo "--- checkpoint markers reported ---"
_snapshot_fail

ARTIFACTS10="$TMPDIR_TEST/artifacts10"
mkdir -p "$ARTIFACTS10"
FAKE_REPO3="$TMPDIR_TEST/repo-marker"
mkdir -p "$FAKE_REPO3"
touch "$FAKE_REPO3/.checkpoint-pending-rollback"

OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS10" REPO_ROOT="$FAKE_REPO3" \
    bash "$HEALTH_CHECK" 2>/dev/null)

assert_contains "checkpoint-pending-rollback in report" "checkpoint-pending-rollback" "$OUTPUT"

assert_pass_if_clean "checkpoint markers reported"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
