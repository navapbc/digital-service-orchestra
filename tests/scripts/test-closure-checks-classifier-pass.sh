#!/usr/bin/env bash
# tests/scripts/test-closure-checks-classifier-pass.sh
# Behavioral smoke test for plugins/dso/scripts/closure-checks-classifier-pass.sh
#
# Testing Mode: GREEN — covers the Phase 2 classifier helper added by story
# ad70-f38a-7684-4e00. Focused on entry-point validation, arg parsing, and
# graceful-degradation paths that do not require a live ANTHROPIC_API_KEY.
# Tests are decoupled from specific live tracker tickets: synthetic ticket-ids
# are paired with pre-created snapshot files so the helper's `ticket show`
# fallback is bypassed.
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

# ── Per-suite temp state (mktemp-managed) ────────────────────────────────────
# Use a per-suite mktemp directory as the parent for all snapshot subdirs so
# parallel-test runs do not collide. Session IDs are mktemp'd too — see
# always:mktemp-tmp.
_SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-classifier-pass.XXXXXX")
trap 'rm -rf "$_SUITE_TMP"' EXIT

# Synthetic ticket-ids that do not exist in any live tracker. The helper reads
# the snapshot file before falling back to `ticket show`, so these IDs never
# need to resolve via the ticket CLI.
SYNTHETIC_TID_DEGRADE="test-classifier-degrade-0001"
SYNTHETIC_TID_APPLY="test-classifier-apply-0002"

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
# Use a synthetic ticket-id + pre-supplied snapshot so the helper skips its
# `ticket show` fallback (which would otherwise contact the live tracker).
SESSION_DEGRADE="degrade-$(basename "$_SUITE_TMP")"
DEGRADE_SNAP_DIR="/tmp/migrate-closure-checks-classify.${SESSION_DEGRADE}.snapshot"
mkdir -p "$DEGRADE_SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- placeholder synthetic item for degradation test\n'
} > "$DEGRADE_SNAP_DIR/${SYNTHETIC_TID_DEGRADE}.txt"

DEGRADE_OUT=$(ANTHROPIC_API_KEY="" "$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_DEGRADE" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_DEGRADE" \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --remaining-budget 1 \
    --dry-run 2>&1)
DEGRADE_RC=$?
if [ "$DEGRADE_RC" = "0" ] && echo "$DEGRADE_OUT" | grep -q "BUDGET_CONSUMED:"; then
    _pass "no-API-key path exits 0 and emits BUDGET_CONSUMED:"
else
    _fail "no-API-key degradation path failed (rc=$DEGRADE_RC, out tail='$(echo "$DEGRADE_OUT" | tail -3)')"
fi
rm -rf "$DEGRADE_SNAP_DIR"

# Test 5: --apply-from-plan with a synthesized empty plan should succeed without classifier dispatch.
# Uses mktemp-managed plan/decisions files + a synthetic ticket-id + pre-created snapshot.
TMP_PLAN=$(mktemp "${TMPDIR:-/tmp}/test-classifier-plan.XXXXXX".json)
TMP_DEC=$(mktemp "${TMPDIR:-/tmp}/test-classifier-dec.XXXXXX".json)
# Note: TMP_PLAN/TMP_DEC are cleaned by the suite-level trap that removes
# $_SUITE_TMP — but they live outside that dir, so clean them explicitly too.
trap 'rm -rf "$_SUITE_TMP"; rm -f "$TMP_PLAN" "$TMP_DEC"' EXIT
cat > "$TMP_PLAN" <<EOF
{
  "schema_version": 1,
  "ticket_id": "$SYNTHETIC_TID_APPLY",
  "snapshot_timestamp": "2026-05-20T00:00:00Z",
  "migration_run_id": "00000000-0000-0000-0000-000000000000",
  "items": []
}
EOF
echo '{"decisions": []}' > "$TMP_DEC"

SESSION_APPLY="apply-$(basename "$_SUITE_TMP")"
APPLY_SNAP_DIR="/tmp/migrate-closure-checks-classify.${SESSION_APPLY}.snapshot"
mkdir -p "$APPLY_SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- placeholder synthetic item for apply test\n'
} > "$APPLY_SNAP_DIR/${SYNTHETIC_TID_APPLY}.txt"

APPLY_OUT=$("$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_APPLY" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_APPLY" \
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
rm -rf "$APPLY_SNAP_DIR"

# Test 6: --apply-from-plan without --decisions-file should error
ERR_OUT=$("$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_APPLY" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_APPLY" \
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
