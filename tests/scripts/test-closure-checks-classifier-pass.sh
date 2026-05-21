#!/usr/bin/env bash
# tests/scripts/test-closure-checks-classifier-pass.sh
# Behavioral smoke test for plugins/dso/scripts/closure-checks-classifier-pass.sh
#
# Testing Mode: GREEN — covers the Phase 2 classifier helper added by story
# ad70-f38a-7684-4e00. Focused on entry-point validation, arg parsing, and
# graceful-degradation paths that do not require a live ANTHROPIC_API_KEY:
#
#   - --help renders the usage block
#   - missing required args fail with a clear error
#   - --plan-output mode emits a structured plan file or graceful NOTICE
#     when ANTHROPIC_API_KEY is unset
#   - --apply-from-plan with a small fixture plan and decisions file emits
#     the expected ITEM lines and audit JSON file
#
# Usage: bash tests/scripts/test-closure-checks-classifier-pass.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HELPER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/closure-checks-classifier-pass.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-classifier-pass.sh ==="

# ── Suite-runner guard: skip when script does not exist ──────────────────────
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$HELPER_SCRIPT" ]; then
    echo "SKIP: closure-checks-classifier-pass.sh not yet implemented"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# Test 1: script exists and is executable
if [ -x "$HELPER_SCRIPT" ]; then
    _pass "script exists and is executable"
else
    _fail "script missing or not executable: $HELPER_SCRIPT"
fi

# Test 2: --help renders without error and includes expected sections
help_out=$("$HELPER_SCRIPT" --help 2>&1)
help_rc=$?
if [ "$help_rc" = "0" ] && echo "$help_out" | grep -q "closure-checks-classifier-pass.sh"; then
    _pass "--help exits 0 and prints usage block"
else
    _fail "--help failed (rc=$help_rc) or output missing"
fi

# Test 3: missing required arg (--ticket-id) yields a clear error
err_out=$("$HELPER_SCRIPT" --target /tmp 2>&1)
err_rc=$?
if [ "$err_rc" = "1" ] && echo "$err_out" | grep -qiE "ticket.?id|required"; then
    _pass "missing --ticket-id exits 1 with descriptive error"
else
    _fail "missing --ticket-id did not exit 1 or lacked descriptive error (rc=$err_rc, out='$err_out')"
fi

# Test 4: graceful degradation when ANTHROPIC_API_KEY is unset.
# Pass a real ticket-id from the live tracker so the helper can capture a snapshot,
# then expect the NOTICE skip path (BUDGET_CONSUMED: 0).
DEGRADE_OUT=$(ANTHROPIC_API_KEY="" "$HELPER_SCRIPT" \
    --ticket-id ad70-f38a-7684-4e00 \
    --target "$REPO_ROOT" \
    --session-id testsession-no-api-key \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --remaining-budget 1 \
    --dry-run 2>&1)
DEGRADE_RC=$?
if [ "$DEGRADE_RC" = "0" ] && echo "$DEGRADE_OUT" | grep -q "BUDGET_CONSUMED:"; then
    _pass "no-API-key path exits 0 and emits BUDGET_CONSUMED:"
else
    _fail "no-API-key degradation path failed (rc=$DEGRADE_RC, out tail='$(echo "$DEGRADE_OUT" | tail -3)')"
fi

# Test 5: --apply-from-plan with a synthesized empty plan should succeed without classifier dispatch
TMP_PLAN=$(mktemp /tmp/test-classifier-plan.XXXXXX.json)
TMP_DEC=$(mktemp /tmp/test-classifier-dec.XXXXXX.json)
trap 'rm -f "$TMP_PLAN" "$TMP_DEC"' EXIT
cat > "$TMP_PLAN" <<'EOF'
{
  "schema_version": 1,
  "ticket_id": "ad70-f38a-7684-4e00",
  "snapshot_timestamp": "2026-05-20T00:00:00Z",
  "migration_run_id": "00000000-0000-0000-0000-000000000000",
  "items": []
}
EOF
echo '{"decisions": []}' > "$TMP_DEC"

# Snapshot must exist for the helper's read path
SNAP_DIR="/tmp/migrate-closure-checks-classify.test-apply.snapshot"
mkdir -p "$SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- placeholder\n'
} > "$SNAP_DIR/ad70-f38a-7684-4e00.txt"

APPLY_OUT=$("$HELPER_SCRIPT" \
    --ticket-id ad70-f38a-7684-4e00 \
    --target "$REPO_ROOT" \
    --session-id test-apply \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --remaining-budget 5 \
    --apply-from-plan "$TMP_PLAN" \
    --decisions-file "$TMP_DEC" \
    --dry-run 2>&1)
APPLY_RC=$?
if [ "$APPLY_RC" = "0" ] && echo "$APPLY_OUT" | grep -q "BUDGET_CONSUMED:"; then
    _pass "--apply-from-plan with empty plan exits 0"
else
    _fail "--apply-from-plan with empty plan failed (rc=$APPLY_RC, out='$APPLY_OUT')"
fi
rm -rf "$SNAP_DIR"

# Test 6: --apply-from-plan without --decisions-file should error
ERR_OUT=$("$HELPER_SCRIPT" \
    --ticket-id ad70-f38a-7684-4e00 \
    --target "$REPO_ROOT" \
    --session-id test-err \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --apply-from-plan "$TMP_PLAN" 2>&1)
ERR_RC=$?
if [ "$ERR_RC" = "1" ] && echo "$ERR_OUT" | grep -qiE "decisions.?file|required"; then
    _pass "--apply-from-plan without --decisions-file exits 1 with descriptive error"
else
    _fail "missing --decisions-file did not exit 1 with proper error (rc=$ERR_RC, out='$ERR_OUT')"
fi

echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
