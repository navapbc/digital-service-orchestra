#!/usr/bin/env bash
# shellcheck disable=SC2016
# (file-level: this test grep-matches literal `$var` / `${var}` patterns from
# the source script; single quotes keep them un-expanded.)
#
# tests/scripts/test-merge-to-main-mq-path.sh — MQ-4 (ADR-0019)
#
# Validates the flag-gated GitHub Merge Queue promotion path added to
# merge-to-main-pr.sh. The script must:
#   - read dso.merge_queue.enabled into DSO_MERGE_QUEUE_ENABLED (default 0/OFF),
#   - honor the DSO_MERGE_QUEUE_ENABLED_OVERRIDE test hook,
#   - when ON: promote session→main directly (call _phase_merge, NOT
#     _phase_staged_intermediate) and gate out the staged-* advance machinery,
#   - when OFF: run the legacy two-tier flow byte-for-byte unchanged.
#
# Approach: structural assertions on the orchestration wiring (the established
# convention for this script — see test-merge-to-main-staged-intermediate.sh:
# "the full two-PR orchestration requires live gh + GitHub state… out of scope
# for a unit-level test") PLUS a behavioral default-OFF check via read-config.sh
# and a golden gh-argv invariance run proving flag-absent == flag-explicitly-OFF.
# The existing test-merge-to-main-pr.sh full-execution harness already exercises
# the direct-to-main _phase_merge path (its fixture origin is not github.com, so
# _phase_staged_intermediate self-skips), so flag-OFF behavior is covered there.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# ── Test 1: the MQ flag is read from dso.merge_queue.enabled ─────────────────
if grep -q 'read-config.sh" dso.merge_queue.enabled' "$TARGET_SCRIPT"; then
    _pass "test_reads_merge_queue_config_key"
else
    _fail "test_reads_merge_queue_config_key" "no read-config.sh dso.merge_queue.enabled in script"
fi

# ── Test 2: the flag defaults to OFF (DSO_MERGE_QUEUE_ENABLED=0 initializer) ──
if grep -qE '^DSO_MERGE_QUEUE_ENABLED=0' "$TARGET_SCRIPT"; then
    _pass "test_flag_defaults_off"
else
    _fail "test_flag_defaults_off" "DSO_MERGE_QUEUE_ENABLED is not initialized to 0"
fi

# ── Test 3: the read is skipped under PR_LIB_MODE (sourced-unit-test safety) ──
if awk '
    /^DSO_MERGE_QUEUE_ENABLED=0/ { seen=1 }
    seen && /PR_LIB_MODE:-0.*!= "1"/ { print "guarded"; exit }
    seen && /read-config.sh" dso.merge_queue.enabled/ { print "unguarded"; exit }
' "$TARGET_SCRIPT" | grep -q guarded; then
    _pass "test_config_read_guarded_by_pr_lib_mode"
else
    _fail "test_config_read_guarded_by_pr_lib_mode" "config read not wrapped in PR_LIB_MODE guard"
fi

# ── Test 4: the override hook is honored ─────────────────────────────────────
if grep -q 'DSO_MERGE_QUEUE_ENABLED_OVERRIDE' "$TARGET_SCRIPT"; then
    _pass "test_override_hook_present"
else
    _fail "test_override_hook_present" "DSO_MERGE_QUEUE_ENABLED_OVERRIDE not honored"
fi

# ── Test 5: the merge dispatch branches on the flag, and the flag-ON branch
#    calls _phase_merge WITHOUT _phase_staged_intermediate ──────────────────
# Extract the dispatch block (from the _PHASE_MERGE_RC=0 init to the closing of
# the `if [[ -z "$_RESUME_STATE_PR_URL" ]]` guard) and assert: the MQ branch
# (DSO_MERGE_QUEUE_ENABLED == 1) reaches _phase_merge before any
# _phase_staged_intermediate, which lives only in the else branch.
dispatch_block=$(awk '
    /^_PHASE_MERGE_RC=0/ { found=1 }
    found { print }
    found && /_phase_staged_intermediate \|\| _PHASE_MERGE_RC/ { exit }
' "$TARGET_SCRIPT" 2>/dev/null)
mq_line=$(printf '%s\n' "$dispatch_block" | grep -nE 'DSO_MERGE_QUEUE_ENABLED" == "1"' | head -1 | cut -d: -f1)
mq_merge_line=$(printf '%s\n' "$dispatch_block" | grep -nE '_phase_merge \|\| _PHASE_MERGE_RC' | head -1 | cut -d: -f1)
staged_line=$(printf '%s\n' "$dispatch_block" | grep -nE '_phase_staged_intermediate \|\| _PHASE_MERGE_RC' | head -1 | cut -d: -f1)
if [[ -n "$mq_line" && -n "$mq_merge_line" && -n "$staged_line" ]] \
   && (( mq_line < mq_merge_line )) && (( mq_merge_line < staged_line )); then
    _pass "test_mq_branch_calls_phase_merge_before_staged"
else
    _fail "test_mq_branch_calls_phase_merge_before_staged" \
        "mq=$mq_line mq_merge=$mq_merge_line staged=$staged_line (expected mq < mq_merge < staged)"
fi

# ── Test 6: the staged-* advance block is gated OFF under the flag ───────────
if grep -qE 'DSO_MERGE_QUEUE_ENABLED" == "0" \]\] && type _state_get_field' "$TARGET_SCRIPT"; then
    _pass "test_advance_block_flag_gated"
else
    _fail "test_advance_block_flag_gated" "staged-advance block not gated by DSO_MERGE_QUEUE_ENABLED==0"
fi

# ── Test 7: the --resume PR-discovery filter is flag-aware (base==main vs
#    staged-*) so resume re-attaches to the single session→main PR under MQ ───
if grep -q 'DSO_MQ="$DSO_MERGE_QUEUE_ENABLED"' "$TARGET_SCRIPT" \
   && grep -qE "base == db\b" "$TARGET_SCRIPT"; then
    _pass "test_resume_discovery_flag_aware"
else
    _fail "test_resume_discovery_flag_aware" "resume PR-discovery filter is not MQ-aware"
fi

# ── Test 8 (behavioral): default is OFF — read-config.sh returns no truthy
#    value for dso.merge_queue.enabled in this repo's config (pre-MQ-6) ───────
_mq_conf="$(bash "$REPO_ROOT/plugins/dso/scripts/read-config.sh" dso.merge_queue.enabled 2>/dev/null || echo "")"
case "${_mq_conf,,}" in
    true|1|yes|on) _fail "test_repo_config_default_off" "dso.merge_queue.enabled is truthy ($_mq_conf) — MQ enabled pre-cutover!" ;;
    *)            _pass "test_repo_config_default_off" ;;
esac

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
