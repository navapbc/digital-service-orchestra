#!/usr/bin/env bash
# test-merge-to-main-pr2-statefile.sh — bug 7a0e
#
# On the FRESH (non --resume) two-tier path, _phase_staged_intermediate re-points
# BRANCH to the staged branch and MUST (re)create the staged-keyed state file via
# _state_init, so _phase_merge's PR2 pr_meta write persists and the polling phase
# can resolve the PR number. The bug: it called the UNDEFINED _state_write_branch
# (a guarded no-op) instead of _state_init, leaving the staged state file absent ->
# _state_write_pr_meta no-ops on its `[[ -f ]]` guard -> PR2 number never persisted
# -> "could not resolve PR number for polling phase", stranding PR2 OPEN.
#
# Two levels:
#  (A) BEHAVIORAL mechanism — executes the REAL merge-helpers.sh state functions
#      to prove the root cause: a staged-keyed state file must be initialized for a
#      field write to persist; without _state_init the write no-ops and the read is
#      empty (exactly how PR2's number was lost).
#  (B) WIRING contract — _phase_* functions need gh/git/push shimming to run
#      end-to-end (see test-merge-to-main-pr-resume-and-stale.sh, which uses the
#      same structural pattern for this reason): assert the re-point block calls
#      _state_init, mirroring the --resume path.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
HELP="$REPO_ROOT/plugins/dso/hooks/lib/merge-helpers.sh"
PR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Unique BRANCH so the (hardcoded /tmp) state file cannot collide under parallel runs.
_UNIQ="$(basename "$(mktemp -u "${TMPDIR:-/tmp}/XXXXXX")")"
BRANCH="staged-${_UNIQ}-1780000000"
_SF="/tmp/merge-to-main-state-${BRANCH//\//-}.json"
_MARKER="/tmp/merge-state-init-marker-${BRANCH//\//-}"
trap 'rm -f "$_SF" "${_SF}.tmp" "$_MARKER"' EXIT

# shellcheck source=/dev/null
source "$HELP"

_read_pr_number() {
    [[ -f "$_SF" ]] || { printf ''; return 0; }
    python3 -c "import json;print(json.load(open('$_SF')).get('pr_number',''))" 2>/dev/null || printf ''
}

# ── (A1) write WITHOUT init must NOT persist (the bug's mechanism) ────────────
rm -f "$_SF"
_state_set_field "pr_number" "777" 2>/dev/null || true
got="$(_read_pr_number)"
if [[ -z "$got" ]]; then _pass "A1_write_without_init_does_not_persist"; else _fail "A1_write_without_init_does_not_persist" "persisted=$got"; fi

# ── (A2) write AFTER _state_init persists and is readable (the fix's mechanism) ─
_state_init 2>/dev/null || true
_state_set_field "pr_number" "531" 2>/dev/null || true
got="$(_read_pr_number)"
if [[ "$got" == "531" ]]; then _pass "A2_write_after_init_persists"; else _fail "A2_write_after_init_persists" "got=$got sf=$_SF"; fi

# ── (B) wiring: the BRANCH re-point block in _phase_staged_intermediate must
#        (re)initialize the staged-keyed state file via _state_init ─────────────
block="$(awk '/^_phase_staged_intermediate\(\)[[:space:]]*\{/{f=1} f{print} f&&/^\}/{exit}' "$PR_SCRIPT")"
if [[ -z "$block" ]]; then
    _fail "B1_repoint_block_calls_state_init" "could not extract _phase_staged_intermediate body"
elif grep -qE 'BRANCH=.*_staged_branch' <<<"$block" && grep -qE '(^|[^_])_state_init' <<<"$block"; then
    _pass "B1_repoint_block_calls_state_init"
else
    _fail "B1_repoint_block_calls_state_init" "re-point block does not call _state_init (staged state file never created)"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
