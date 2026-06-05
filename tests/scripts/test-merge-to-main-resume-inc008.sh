#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-resume-inc008.sh — 3ebb DD2 (durable --resume)
#
# INC-008 GUARD (LOAD-BEARING): when --resume reconstructs pipeline state from
# GitHub, an INCOMPLETE / partial / failed PR-state read MUST be treated as
# INDETERMINATE — NEVER as authoritative-empty ("no PRs"). Acting on partial
# state as "no PRs" re-creates the stall this kills: a duplicate staged-* ref +
# PR1, or a lost live session. A legitimately-empty result ("[]", rc 0) is
# distinct and trustworthy.
#
# Tests resume_pr_query_trustworthy (pure decision function) behaviorally:
#   returns 0  = trustworthy (safe to parse, incl. a real empty list)
#   returns 75 = INDETERMINATE (re-fetch/escalate; never treat as "no PRs")

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT/plugins/dso"
MERGE_PR="$CLAUDE_PLUGIN_ROOT/scripts/merge-to-main-pr.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Load merge-to-main-pr.sh in lib mode (defines functions, returns before main flow).
export PR_LIB_MODE=1
# shellcheck source=/dev/null
source "$MERGE_PR" 2>/dev/null || true
unset PR_LIB_MODE

if ! type resume_pr_query_trustworthy >/dev/null 2>&1; then
    _fail "function_defined" "resume_pr_query_trustworthy not loaded from $MERGE_PR"
    echo ""; echo "PASSED: $PASS  FAILED: $FAIL"; exit 1
fi
_pass "function_defined"

# ── Trustworthy: rc 0 + well-formed JSON (incl. a legitimately-empty list) ───
resume_pr_query_trustworthy 0 "[]"; rc=$?
if [[ $rc -eq 0 ]]; then _pass "T1_empty_list_is_trustworthy"; else _fail "T1_empty_list_is_trustworthy" "rc=$rc (a real [] must be trusted, not INDETERMINATE)"; fi
resume_pr_query_trustworthy 0 '[{"number":5,"state":"open"}]'; rc=$?
if [[ $rc -eq 0 ]]; then _pass "T2_nonempty_list_is_trustworthy"; else _fail "T2_nonempty_list_is_trustworthy" "rc=$rc"; fi
resume_pr_query_trustworthy 0 '{"number":7}'; rc=$?
if [[ $rc -eq 0 ]]; then _pass "T3_object_is_trustworthy"; else _fail "T3_object_is_trustworthy" "rc=$rc"; fi

# ── INDETERMINATE: the call failed (rc != 0) — never trust the payload ───────
resume_pr_query_trustworthy 1 "[]"; rc=$?
if [[ $rc -eq 75 ]]; then _pass "T4_nonzero_rc_is_indeterminate"; else _fail "T4_nonzero_rc_is_indeterminate" "rc=$rc (a failed call must NOT be read as 'no PRs')"; fi

# ── INDETERMINATE: empty payload (a real empty list is "[]", not "") ─────────
resume_pr_query_trustworthy 0 ""; rc=$?
if [[ $rc -eq 75 ]]; then _pass "T5_empty_payload_is_indeterminate"; else _fail "T5_empty_payload_is_indeterminate" "rc=$rc"; fi

# ── INDETERMINATE: truncated / malformed JSON (pagination cut short, etc.) ───
resume_pr_query_trustworthy 0 '[{"number":5'; rc=$?
if [[ $rc -eq 75 ]]; then _pass "T6_truncated_json_is_indeterminate"; else _fail "T6_truncated_json_is_indeterminate" "rc=$rc"; fi
resume_pr_query_trustworthy 0 'not json at all'; rc=$?
if [[ $rc -eq 75 ]]; then _pass "T7_garbage_payload_is_indeterminate"; else _fail "T7_garbage_payload_is_indeterminate" "rc=$rc"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
