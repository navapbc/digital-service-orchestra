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

# Hermeticity: isolate every git operation in this test from the runner's ambient
# git environment. Without this, a CI runner (or developer) with global git hooks,
# commit signing, or custom aliases in ~/.gitconfig (or /etc/gitconfig) would leak
# into the init/clone/commit/push below and make them behave unpredictably. The
# local `git config user.*`/`commit.gpgsign false` set per-repo does NOT override
# user-global or system config, so neutralize both config layers at the source.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

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

# ── INC-015: resume_staged_ref_is_spent (pure predicate) ─────────────────────
if ! type resume_staged_ref_is_spent >/dev/null 2>&1; then
    _fail "spent_fn_defined" "resume_staged_ref_is_spent not loaded"
else
    _pass "spent_fn_defined"
    if resume_staged_ref_is_spent "0"; then _pass "T8_zero_ahead_is_spent"; else _fail "T8_zero_ahead_is_spent" "0 should be spent"; fi
    if ! resume_staged_ref_is_spent "3"; then _pass "T9_positive_ahead_not_spent"; else _fail "T9_positive_ahead_not_spent" "3 should NOT be spent"; fi
    # fail-safe: unknown ahead-count is NOT spent (never skip/GC on uncertainty)
    if ! resume_staged_ref_is_spent ""; then _pass "T10_empty_not_spent_failsafe"; else _fail "T10_empty_not_spent_failsafe" "empty should be NOT spent"; fi
    if ! resume_staged_ref_is_spent "x"; then _pass "T11_nonnumeric_not_spent_failsafe"; else _fail "T11_nonnumeric_not_spent_failsafe" "non-numeric should be NOT spent"; fi
fi

# ── INC-015 (b): resume_gc_stale_staged_state GCs spent/gone cache, keeps live ──
if ! type resume_gc_stale_staged_state >/dev/null 2>&1; then
    _fail "gc_fn_defined" "resume_gc_stale_staged_state not loaded"
else
    _pass "gc_fn_defined"
    GCW=$(mktemp -d "${TMPDIR:-/tmp}/inc008-gc.XXXXXX"); trap 'rm -rf "$GCW"' EXIT  # cleanup even on early exit/interrupt
    ORIGIN="$GCW/origin.git"; git init -q --bare "$ORIGIN"
    SEED="$GCW/seed"; git clone -q "$ORIGIN" "$SEED" 2>/dev/null
    # Push HEAD directly to named remote refs — do NOT reference a local branch
    # name ('main'/'master' varies by git init.defaultBranch and broke in CI).
    ( cd "$SEED" || exit 1
      git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
      echo base > b.txt; git add b.txt; git commit -qm M0
      git push -q origin HEAD:refs/heads/main
      git push -q origin HEAD:refs/heads/staged-spent          # == main -> 0 ahead -> spent
      echo x > x.txt; git add x.txt; git commit -qm L1
      git push -q origin HEAD:refs/heads/staged-live )         # 1 ahead -> live
    RUN="$GCW/run"; git clone -q "$ORIGIN" "$RUN" 2>/dev/null
    SD="$GCW/state"; mkdir -p "$SD"
    echo '{}' > "$SD/merge-to-main-state-staged-spent.json"
    echo '{}' > "$SD/merge-to-main-state-staged-live.json"
    echo '{}' > "$SD/merge-to-main-state-staged-gone.json"   # no such branch on origin
    ( cd "$RUN" && resume_gc_stale_staged_state "$SD" ) >/dev/null 2>&1
    if [[ ! -f "$SD/merge-to-main-state-staged-spent.json" ]]; then _pass "T12_gc_removes_spent"; else _fail "T12_gc_removes_spent" "spent cache not removed"; fi
    if [[ ! -f "$SD/merge-to-main-state-staged-gone.json" ]]; then _pass "T13_gc_removes_gone"; else _fail "T13_gc_removes_gone" "gone-branch cache not removed"; fi
    if [[ -f "$SD/merge-to-main-state-staged-live.json" ]]; then _pass "T14_gc_keeps_live"; else _fail "T14_gc_keeps_live" "live cache wrongly removed"; fi
    rm -rf "$GCW"
fi

# ── R-A predicate: _branch_is_staged_promotion (PR2-phase gate, both polarities) ──
# The publish-block skip for staged-* keys on this predicate. Asserting BOTH
# polarities ensures the skip is not a dormant one-way gate: staged-* -> skip
# (true); a non-staged source branch -> DO run the publish block (false), so the
# rebase+force-publish path for source branches is NOT disabled (that path's
# behavior is itself covered by test-merge-to-main-pr-linear-sync.sh D1-D6).
if ! type _branch_is_staged_promotion >/dev/null 2>&1; then
    _fail "predicate_defined" "_branch_is_staged_promotion not loaded"
else
    _pass "predicate_defined"
    if _branch_is_staged_promotion "staged-abc123def456-1780000000"; then _pass "T15_staged_is_promotion"; else _fail "T15_staged_is_promotion" "staged-* must be a promotion (true)"; fi
    if ! _branch_is_staged_promotion "story/588e-abec-221f-42c0/feat-x"; then _pass "T16_feature_branch_not_promotion"; else _fail "T16_feature_branch_not_promotion" "a feature branch must NOT be a promotion (false)"; fi
    if ! _branch_is_staged_promotion ""; then _pass "T17_empty_not_promotion"; else _fail "T17_empty_not_promotion" "empty must be false"; fi
    # default arg reads $BRANCH (save/restore)
    _saved_branch="${BRANCH:-}"
    BRANCH="staged-zzz-1"; if _branch_is_staged_promotion; then _pass "T18_default_reads_BRANCH_staged"; else _fail "T18_default_reads_BRANCH_staged" "default should read \$BRANCH"; fi
    BRANCH="main"; if ! _branch_is_staged_promotion; then _pass "T19_default_reads_BRANCH_nonstaged"; else _fail "T19_default_reads_BRANCH_nonstaged" "main must be false"; fi
    BRANCH="$_saved_branch"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
