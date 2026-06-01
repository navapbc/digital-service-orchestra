#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-resume-staged-advance.sh
#
# Resume hardening: a crash after PR1 (source→staged) merged but before the
# worktree's checkout to staged-* persisted previously caused a later --resume to
# re-create a DUPLICATE staged ref + PR1 (the worktree-derived BRANCH was stale).
# The fix persists the staged branch name in the SOURCE-branch-keyed state file and
# advances to PR2 only when PR1 has merged AND the staged branch still exists.
#
# Tests the two load-bearing units behaviorally:
#   (1) _resume_should_advance_to_staged decision (pure function)
#   (2) state round-trip of the persisted staged_branch field

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT/plugins/dso"
MERGE_PR="$CLAUDE_PLUGIN_ROOT/scripts/merge-to-main-pr.sh"
HELPERS="$CLAUDE_PLUGIN_ROOT/hooks/lib/merge-helpers.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Load the script in lib mode (defines functions, returns before the main flow).
export PR_LIB_MODE=1
# shellcheck source=/dev/null
source "$MERGE_PR" 2>/dev/null || true
unset PR_LIB_MODE
# shellcheck source=/dev/null
source "$HELPERS" 2>/dev/null || true

# ── (1) decision function ────────────────────────────────────────────────────
if ! type _resume_should_advance_to_staged >/dev/null 2>&1; then
    _fail "function_defined" "_resume_should_advance_to_staged not loaded from $MERGE_PR"
else
    _pass "function_defined"
    # PR1 merged (open=0) + staged exists (>0) → ADVANCE
    if _resume_should_advance_to_staged "0" "1"; then _pass "T1_advance_when_pr1_merged_and_staged_exists"; else _fail "T1_advance_when_pr1_merged_and_staged_exists" "expected advance"; fi
    # PR1 still open → do NOT advance (finish PR1 first)
    if ! _resume_should_advance_to_staged "1" "1"; then _pass "T2_no_advance_when_pr1_open"; else _fail "T2_no_advance_when_pr1_open" "advanced while PR1 open"; fi
    # staged branch gone → do NOT advance
    if ! _resume_should_advance_to_staged "0" "0"; then _pass "T3_no_advance_when_staged_missing"; else _fail "T3_no_advance_when_staged_missing" "advanced with no staged branch"; fi
    # fail-safe defaults (gh/git failure → "1"/"0") → do NOT advance
    if ! _resume_should_advance_to_staged "1" "0"; then _pass "T4_failsafe_no_advance"; else _fail "T4_failsafe_no_advance" "advanced under uncertainty"; fi
fi

# ── (2) staged_branch state round-trip (source-branch-keyed file) ────────────
if type _state_set_field >/dev/null 2>&1 && type _state_get_field >/dev/null 2>&1 && type _state_init >/dev/null 2>&1; then
    # Use a unique BRANCH so the state file path is isolated; clean up after.
    BRANCH="feat/resume-test-$$-${RANDOM}"
    _SF="$(_state_file_path)"
    _state_init 2>/dev/null || true
    _state_set_field "staged_branch" "staged-abc123-1780000000" 2>/dev/null || true
    got="$(_state_get_field "staged_branch" "" 2>/dev/null || true)"
    if [[ "$got" == "staged-abc123-1780000000" ]]; then
        _pass "T5_staged_branch_state_roundtrip"
    else
        _fail "T5_staged_branch_state_roundtrip" "got='$got'"
    fi
    # Absent field returns the default (no crash).
    missing="$(_state_get_field "staged_branch_absent" "DEFLT" 2>/dev/null || true)"
    if [[ "$missing" == "DEFLT" ]]; then _pass "T6_absent_field_default"; else _fail "T6_absent_field_default" "got='$missing'"; fi
    rm -f "$_SF" 2>/dev/null || true
else
    _fail "state_helpers_loaded" "state field helpers not available"
fi

# ── (3) version bump skips on a staged-* source branch (two-tier flow) ───────
# The PR2 phase must NOT push a fresh bump commit to the protected staged-* branch
# (the sub-PR ruleset rejects it for the non-admin agent). The bump is applied on
# the feature branch during PR1 instead.
if type _phase_source_branch_version_bump >/dev/null 2>&1; then
    BRANCH="staged-deadbeef-1780000000"
    out="$(_phase_source_branch_version_bump "story-x" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && grep -q "staged-\* (PR2 phase)" <<<"$out"; then
        _pass "T7_version_bump_skips_on_staged_source"
    else
        _fail "T7_version_bump_skips_on_staged_source" "rc=$rc out=$out"
    fi
else
    _fail "version_bump_fn_defined" "_phase_source_branch_version_bump not loaded"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
